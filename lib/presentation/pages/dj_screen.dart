import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/services/playlist_store.dart';
import 'package:tk_music/presentation/widgets/app_header.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';
import 'package:tk_music/presentation/widgets/dj/dj_controller_dialogs.dart';
import 'package:tk_music/presentation/widgets/dj/dj_controls.dart';
import 'package:tk_music/presentation/widgets/dj/dj_file_browser.dart';
import 'package:tk_music/presentation/widgets/dj/dj_shortcuts.dart';
import 'package:tk_music/presentation/widgets/dj/dj_visuals.dart';
import 'package:tk_music/services/app_audio_handler.dart';
import 'package:tk_music/services/automix_engine.dart';
import 'package:tk_music/services/dj/dj_auto_dj.dart';
import 'package:tk_music/services/dj/dj_controller.dart';
import 'package:tk_music/services/dj/dj_deck.dart';
import 'package:tk_music/services/dj/dj_math.dart';
import 'package:tk_music/services/dj/dj_mixer.dart';
import 'package:tk_music/services/dj/music_files.dart' show showInFileManager;
import 'package:tk_music/services/dj/dj_settings_store.dart';
import 'package:tk_music/services/dj/mix_recorder.dart';
import 'package:tk_music/services/track_features.dart';
import 'package:tk_music/services/track_features_store.dart';

/// Modo DJ (solo desktop): un mini controlador al estilo VirtualDJ con dos
/// decks, mezclador y navegador de la biblioteca. Arriba las dos formas de
/// onda con la grilla de pulsos; al medio los decks (plato, pitch, cue,
/// play, sync, puntos, bucles y saltos) y el mezclador (ecualizador,
/// volúmenes, crossfader y mezcla automática). Todo se puede manejar con el
/// teclado (ver dj_shortcuts.dart) y la salida se puede grabar.
class DjScreen extends StatefulWidget {
  const DjScreen({super.key, @visibleForTesting this.librarySongs});

  /// Para los tests: la biblioteca sin pasar por los providers de la app.
  final List<Song>? librarySongs;

  @override
  State<DjScreen> createState() => _DjScreenState();
}

class _DjScreenState extends State<DjScreen>
    with SingleTickerProviderStateMixin {
  late final DjMixer _mixer;
  late final Ticker _ticker;

  /// Cada cuadro (formas de onda y platos) y ~10 veces por segundo (textos).
  final _frame = ValueNotifier<int>(0);
  final _slow = ValueNotifier<int>(0);

  /// Mezclador desplegado (se recuerda entre sesiones).
  bool _mixerOpen = true;
  final _settings = DjSettingsStore();

  /// Modo de los pads de cada deck (lo cambian las pestañas y las teclas
  /// 5 y 6).
  final _padModes = [
    ValueNotifier(_PadMode.hotCue),
    ValueNotifier(_PadMode.hotCue),
  ];

  /// Largo de la mezcla automática, en pulsos.
  final _mixBeats = ValueNotifier<int>(16);

  /// "Grabar mezcla": la salida estéreo de la computadora a un WAV.
  final _recorder = MixRecorder();

  /// Recibe las teclas del Modo DJ.
  final _focus = FocusNode(debugLabel: 'Modo DJ');

  /// Controladores DJ por MIDI (Numark Mixtrack Pro 3): se detectan solos.
  late final DjControllerHub _controllers;

  /// Dónde están los altavoces (con un controlador con placa de sonido).
  DjSpeakers _speakers = DjSpeakers.computer;

  bool _libraryOpen = false;

  /// Auto DJ: la lista que suena sola, mezclándose.
  late final DjAutoDj _autoDj;

  Future<void> _toggleMixer() async {
    setState(() => _mixerOpen = !_mixerOpen);
    await _settings.setMixerOpen(_mixerOpen);
  }

  @override
  void initState() {
    super.initState();
    AppAudioHandler? main;
    if (isAudioAvailable) {
      final handler = sl<AudioHandler>();
      unawaited(handler.pause());
      if (handler is AppAudioHandler) main = handler as AppAudioHandler;
    }
    // El Mezclador automático usa sus propios reproductores: no pueden
    // sonar los dos a la vez.
    if (AutomixEngine.instance.status != AutomixStatus.idle) {
      unawaited(AutomixEngine.instance.stop());
    }
    unawaited(TrackFeaturesStore.instance.warmUp().then((_) {
      if (mounted) setState(() {});
    }));
    _mixer = DjMixer(mainPlayer: main);
    _autoDj = DjAutoDj(_mixer, beats: _mixBeats.value);
    _mixBeats.addListener(() => _autoDj.beats = _mixBeats.value);
    if (widget.librarySongs == null) unawaited(_autoDj.restore());
    _recorder.onInterrupted = _say;
    _controllers = DjControllerHub(
      mixer: _mixer,
      actions: DjControllerActions(
        onPadMode: (deck) {
          final mode = _padModes[_deckIndex(deck)];
          mode.value =
              _PadMode.values[(mode.value.index + 1) % _PadMode.values.length];
        },
        onLoad: (deck) {
          if (!_libraryOpen) unawaited(_openLibrary(deck));
        },
        onMessage: _say,
      ),
    )
      ..onConnected = _onControllerConnected
      ..onDisconnected = _onControllerDisconnected;
    // En los tests no hay controladores que buscar.
    if (widget.librarySongs == null) {
      unawaited(_settings.invertPitch().then((invert) {
        _controllers.setInvertPitch(invert);
        _controllers.addListener(() {
          unawaited(_settings.setInvertPitch(_controllers.invertPitch));
        });
      }));
      _controllers.start();
    }
    unawaited(_settings.mixerOpen().then((open) {
      if (open != null && mounted) setState(() => _mixerOpen = open);
    }));
    _ticker = createTicker((elapsed) {
      _frame.value++;
      if (_frame.value % 6 == 0) _slow.value++;
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _autoDj.dispose();
    _controllers.dispose();
    _recorder.dispose();
    _mixer.dispose();
    for (final mode in _padModes) {
      mode.dispose();
    }
    _mixBeats.dispose();
    _focus.dispose();
    _frame.dispose();
    _slow.dispose();
    super.dispose();
  }

  void _say(String? message) {
    if (message == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _load(DjDeck deck, Song song) async {
    if (deck.playing) {
      _say('El deck ${deck.label} está sonando: frenalo antes de cargar '
          'otra canción.');
      return;
    }
    await deck.load(song);
  }

  /// Doble clic en la biblioteca: al deck que no está sonando.
  Future<void> _loadToFree(Song song) async {
    final free = !_mixer.a.playing
        ? _mixer.a
        : !_mixer.b.playing
            ? _mixer.b
            : null;
    if (free == null) {
      _say('Los dos decks están sonando: frená uno para cargar.');
      return;
    }
    await _load(free, song);
  }

  /// El gestor de archivos (biblioteca y discos, solo MP3/WAV) en una
  /// ventana encima de los decks. Con [target], tocar una canción la carga
  /// en ese deck; sin él, cada fila tiene A y B (y el doble clic va al deck
  /// libre).
  Future<void> _openLibrary(DjDeck? target) async {
    final songs = widget.librarySongs ?? AppProviders.songOf(context).songs;
    _libraryOpen = true;
    try {
      await _showLibrary(target, songs);
    } finally {
      _libraryOpen = false;
    }
  }

  Future<void> _showLibrary(DjDeck? target, List<Song> songs) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final size = MediaQuery.sizeOf(dialogContext);
        void close() => Navigator.of(dialogContext).pop();
        return Theme(
          data: Theme.of(context),
          child: Dialog(
            backgroundColor: DjColors.panel,
            insetPadding: const EdgeInsets.all(24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: target == null
                    ? DjColors.border
                    : DjColors.forDeck(target.label).withValues(alpha: 0.6),
              ),
            ),
            child: SizedBox(
              width: math.min(1100, size.width - 48),
              height: math.min(760, size.height - 48),
              child: DjFileBrowser(
                mixer: _mixer,
                librarySongs: songs,
                target: target,
                onClose: close,
                onLoad: (deck, song) async {
                  if (deck.playing) {
                    _say('El deck ${deck.label} está sonando: frenalo antes '
                        'de cargar otra canción.');
                    return;
                  }
                  close();
                  await _load(deck, song);
                },
                onLoadToFree: (song) async {
                  close();
                  await _loadToFree(song);
                },
                // Si se borró algo de la biblioteca, se vuelve a leer.
                onFilesDeleted: (paths) {
                  final library = {for (final s in songs) s.filePath};
                  if (widget.librarySongs == null &&
                      paths.any(library.contains)) {
                    unawaited(AppProviders.songOf(context).loadSongs());
                  }
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Future<bool> _confirmExit() async {
    final recording = _recorder.recording;
    if (!_mixer.decks.any((d) => d.playing) && !recording) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Salir del modo DJ?'),
        content: Text(recording
            ? 'La música de los decks se va a detener y se termina la '
                'grabación (lo grabado hasta acá queda guardado).'
            : 'La música de los decks se va a detener.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Seguir mezclando'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Salir'),
          ),
        ],
      ),
    );
    return leave ?? false;
  }

  // -------------------------------------------------------------------------
  // Ecualizador y Auto DJ (en ventanas)
  // -------------------------------------------------------------------------

  Future<void> _openEqualizer() => showDialog<void>(
        context: context,
        builder: (_) => _EqualizerDialog(mixer: _mixer),
      );

  Future<void> _openAutoDj() => showDialog<void>(
        context: context,
        builder: (_) => _AutoDjDialog(
          autoDj: _autoDj,
          mixBeats: _mixBeats,
          onAddFromFiles: _addToAutoDjFromFiles,
          onAddPlaylist: _addToAutoDjFromPlaylist,
          onMessage: _say,
        ),
      );

  /// El gestor de archivos para sumar canciones a la lista del Auto DJ.
  Future<void> _addToAutoDjFromFiles(BuildContext dialogContext) {
    final songs = widget.librarySongs ?? AppProviders.songOf(context).songs;
    return showDialog<void>(
      context: dialogContext,
      builder: (browserContext) {
        final size = MediaQuery.sizeOf(browserContext);
        void close() => Navigator.of(browserContext).pop();
        return Theme(
          data: Theme.of(context),
          child: Dialog(
            backgroundColor: DjColors.panel,
            insetPadding: const EdgeInsets.all(24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: DjColors.cue),
            ),
            child: SizedBox(
              width: math.min(1100, size.width - 48),
              height: math.min(760, size.height - 48),
              child: DjFileBrowser(
                mixer: _mixer,
                librarySongs: songs,
                onLoad: (_, __) async {},
                onLoadToFree: (_) async {},
                onClose: close,
                onQueue: (song) => _autoDj.add([song]),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Una lista de reproducción guardada, entera, al final del Auto DJ.
  Future<void> _addToAutoDjFromPlaylist(BuildContext dialogContext) async {
    final library = widget.librarySongs ?? AppProviders.songOf(context).songs;
    final byId = {for (final song in library) song.mediaStoreId: song};
    final playlists = await PlaylistStore.instance.getAll();
    if (!dialogContext.mounted) return;
    final chosen = await showDialog<int>(
      context: dialogContext,
      builder: (listContext) => SimpleDialog(
        title: const Text('Agregar una lista guardada'),
        children: [
          if (playlists.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Text('Todavía no tenés listas guardadas.'),
            ),
          for (final (i, playlist) in playlists.indexed)
            SimpleDialogOption(
              onPressed: () => Navigator.of(listContext).pop(i),
              child: Text('${playlist.name} · '
                  '${playlist.songIds.length} canciones'),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    final songs = [
      for (final id in playlists[chosen].songIds)
        if (byId[id] != null) byId[id]!,
    ];
    _autoDj.add(songs);
    _say('Se agregaron ${songs.length} canciones al Auto DJ.');
  }

  // -------------------------------------------------------------------------
  // Controlador DJ
  // -------------------------------------------------------------------------

  /// La placa de sonido de [profile], si Windows la muestra.
  Future<DjAudioDevice?> _controllerAudio(DjControllerProfile profile) async {
    if (!profile.hasSoundCard) return null;
    for (final device in await _mixer.a.audioDevices()) {
      if (profile.matchesAudio(device.description)) return device;
    }
    return null;
  }

  /// Recién enchufado: la ventana de "nuevo dispositivo detectado" (salvo
  /// que se haya marcado "no mostrar de nuevo") y los altavoces elegidos.
  Future<void> _onControllerConnected(DjControllerProfile profile) async {
    final saved = await _settings.controllerSpeakers(profile.id);
    final silent = await _settings.controllerSilent(profile.id);
    final audio = await _controllerAudio(profile);
    if (!mounted) return;
    var speakers = saved == DjSpeakers.controller.name
        ? DjSpeakers.controller
        : DjSpeakers.computer;
    if (silent) {
      _say('${profile.shortName} conectado.');
    } else {
      final choice = await DjControllerDetectedDialog.show(
        context,
        profile: profile,
        controllerAudioFound: audio != null,
        initial: speakers,
      );
      if (!mounted) return;
      if (choice != null) {
        speakers = choice.speakers;
        await _settings.setControllerSpeakers(profile.id, speakers.name);
        await _settings.setControllerSilent(profile.id, choice.dontShowAgain);
      }
    }
    await _applySpeakers(profile, speakers, audio);
  }

  Future<void> _applySpeakers(DjControllerProfile profile, DjSpeakers speakers,
      [DjAudioDevice? audio]) async {
    if (speakers == _speakers && speakers == DjSpeakers.computer) return;
    if (_recorder.recording) {
      _say('Terminá la grabación antes de cambiar los altavoces.');
      return;
    }
    if (speakers == DjSpeakers.controller) {
      audio ??= await _controllerAudio(profile);
      if (audio == null) {
        _say('Windows no muestra la placa de sonido del '
            '${profile.shortName}: el sonido sigue en la computadora.');
        speakers = DjSpeakers.computer;
      }
    }
    await _mixer.setOutputDevice(
        speakers == DjSpeakers.controller ? audio!.name : 'auto');
    if (!mounted) return;
    setState(() => _speakers = speakers);
    _say(speakers == DjSpeakers.controller
        ? '${profile.shortName} conectado: el sonido sale por su salida '
            'MASTER.'
        : '${profile.shortName} conectado: el sonido sale por la '
            'computadora.');
  }

  void _onControllerDisconnected(DjControllerProfile profile) {
    if (!mounted) return;
    final wasOnController = _mixer.outputDevice != 'auto';
    if (wasOnController) unawaited(_mixer.setOutputDevice('auto'));
    setState(() => _speakers = DjSpeakers.computer);
    _say('Se desconectó el ${profile.shortName}'
        '${wasOnController ? ': el sonido vuelve a la computadora' : ''}.');
  }

  Future<void> _openControllerPanel() async {
    final profile = _controllers.profile;
    if (profile == null) return;
    final audio = await _controllerAudio(profile);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => DjControllerPanel(
        hub: _controllers,
        speakers: _speakers,
        controllerAudioFound: audio != null,
        onSpeakers: (speakers) async {
          await _applySpeakers(profile, speakers, audio);
          await _settings.setControllerSpeakers(profile.id, _speakers.name);
        },
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Grabar mezcla
  // -------------------------------------------------------------------------

  /// La salida de Windows por la que suenan los decks (para grabar esa).
  String? get _outputWindowsId {
    final device = _mixer.outputDevice;
    return device.startsWith('wasapi/') ? device.substring(7) : null;
  }

  Future<void> _toggleRecording() async {
    final wasRecording = _recorder.recording;
    final message = await _recorder.toggle(deviceId: _outputWindowsId);
    if (!mounted) return;
    if (!wasRecording) {
      _say(message ??
          'Grabando la mezcla: solo lo que sale por los parlantes, en '
              'estéreo. F9 o el botón rojo la terminan.');
      return;
    }
    final path = _recorder.path;
    if (message == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 8),
        action: path == null
            ? null
            : SnackBarAction(
                label: 'Ver archivo',
                onPressed: () => showInFileManager(path),
              ),
      ));
  }

  // -------------------------------------------------------------------------
  // Teclado
  // -------------------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    final binding = djBindingFor(
      event,
      shift: keyboard.isShiftPressed,
      alt: keyboard.isAltPressed,
      control: keyboard.isControlPressed,
      meta: keyboard.isMetaPressed,
    );
    if (binding == null) return KeyEventResult.ignored;
    unawaited(_run(binding));
    return KeyEventResult.handled;
  }

  Future<void> _nudgePitch(DjDeck deck, double step) {
    final next = ((deck.pitch + step) * 10000).round() / 10000;
    return deck.setPitch(next.clamp(-deck.range, deck.range));
  }

  Future<void> _moveCrossfader(double value) async {
    if (_mixer.mixingTo != null) _mixer.cancelAutoMix();
    await _mixer.setCrossfader(value);
  }

  Future<void> _run(DjKeyBinding b) async {
    if (b.deck != null) return _runDeck(b, _mixer.decks[b.deck!]);
    switch (b.command) {
      case DjCommand.crossfaderLeft:
        await _moveCrossfader(_mixer.crossfader - 0.05);
      case DjCommand.crossfaderRight:
        await _moveCrossfader(_mixer.crossfader + 0.05);
      case DjCommand.crossfaderFullLeft:
        await _moveCrossfader(-1);
      case DjCommand.crossfaderFullRight:
        await _moveCrossfader(1);
      case DjCommand.crossfaderCenter:
        await _moveCrossfader(0);
      case DjCommand.masterDown:
        await _mixer.setMaster(_mixer.master - 0.05);
      case DjCommand.masterUp:
        await _mixer.setMaster(_mixer.master + 0.05);
      case DjCommand.autoMix:
        if (_mixer.mixingTo != null) {
          _mixer.cancelAutoMix();
        } else {
          _say(await _mixer.autoMix(beats: _mixBeats.value));
        }
      case DjCommand.mixBeats:
        _mixBeats.value = b.arg;
        _say('Mezcla automática en ${b.arg} pulsos');
      case DjCommand.files:
        await _openLibrary(null);
      case DjCommand.toggleMixer:
        await _toggleMixer();
      case DjCommand.record:
        await _toggleRecording();
      case DjCommand.help:
        await DjShortcutsDialog.show(context);
      case DjCommand.equalizer:
        await _openEqualizer();
      case DjCommand.autoDj:
        await _openAutoDj();
      default:
        break;
    }
  }

  Future<void> _runDeck(DjKeyBinding b, DjDeck deck) async {
    final loaded = deck.loaded;
    final mode = _padModes[b.deck!];
    switch (b.command) {
      case DjCommand.cue:
        if (loaded) await deck.cue();
      case DjCommand.play:
        if (loaded) await deck.togglePlay();
      case DjCommand.sync:
        if (loaded) _say(await _mixer.sync(deck));
      case DjCommand.autoSync:
        if (loaded) _say(await _mixer.setAutoSync(deck, !deck.autoSync));
      case DjCommand.keySync:
        if (loaded) _say(await _mixer.syncKey(deck));
      case DjCommand.keyReset:
        if (loaded) await deck.setKeyShift(0);
      case DjCommand.pad:
        _padSpecs(deck, mode.value)[b.arg].onTap?.call();
      case DjCommand.padClear:
        if (deck.hotCues[b.arg] != null) deck.clearHotCue(b.arg);
      case DjCommand.padMode:
        mode.value =
            _PadMode.values[(mode.value.index + 1) % _PadMode.values.length];
      case DjCommand.pitchDown:
        await _nudgePitch(deck, b.arg == 1 ? -0.01 : -0.001);
      case DjCommand.pitchUp:
        await _nudgePitch(deck, b.arg == 1 ? 0.01 : 0.001);
      case DjCommand.pitchReset:
        await deck.setPitch(0);
      case DjCommand.pitchRange:
        final i = djPitchRanges.indexOf(deck.range);
        await deck.setRange(djPitchRanges[(i + 1) % djPitchRanges.length]);
      case DjCommand.keylock:
        await deck.setKeylock(!deck.keylock);
      case DjCommand.semitoneDown:
        if (loaded) await deck.setKeyShift(deck.keyShift - 1);
      case DjCommand.semitoneUp:
        if (loaded) await deck.setKeyShift(deck.keyShift + 1);
      case DjCommand.load:
        await _openLibrary(deck);
      case DjCommand.testOutput:
        await _mixer.testOutput(deck);
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final theme = base.copyWith(
      scaffoldBackgroundColor: DjColors.background,
      colorScheme: base.colorScheme.copyWith(
        surface: DjColors.panel,
        primary: DjColors.deckA,
      ),
    );
    return Theme(
      data: theme,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final navigator = Navigator.of(context);
          if (await _confirmExit()) navigator.pop();
        },
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Listener(
            // Un clic en cualquier lado devuelve las teclas a los decks.
            onPointerDown: (_) {
              if (!_focus.hasFocus) _focus.requestFocus();
            },
            child: Scaffold(
              backgroundColor: DjColors.background,
              appBar: AppBar(
                backgroundColor: DjColors.panel,
                title: const AppHeaderTitle(section: 'Modo DJ'),
                actions: [
                  ListenableBuilder(
                    listenable: _controllers,
                    builder: (context, _) {
                      final profile = _controllers.profile;
                      if (profile == null) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Tooltip(
                          message: 'Controlador conectado: altavoces, qué hace '
                              'cada control y monitor',
                          child: ActionChip(
                            avatar: const Icon(Icons.settings_input_component,
                                size: 18, color: Color(0xFF3DDC84)),
                            label: Text(profile.shortName),
                            onPressed: _openControllerPanel,
                          ),
                        ),
                      );
                    },
                  ),
                  ListenableBuilder(
                    listenable: _autoDj,
                    builder: (context, _) => Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Tooltip(
                        message:
                            'Auto DJ: una lista que suena sola, mezclándose '
                            'una con otra${djShortcutHint(DjCommand.autoDj)}',
                        child: _autoDj.running
                            ? FilledButton.icon(
                                style: FilledButton.styleFrom(
                                    backgroundColor: DjColors.loop,
                                    foregroundColor: Colors.black),
                                onPressed: _openAutoDj,
                                icon: const Icon(Icons.queue_play_next),
                                label: Text('Auto DJ · '
                                    '${_autoDj.items.where((i) => i.played).length}'
                                    '/${_autoDj.items.length}'),
                              )
                            : OutlinedButton.icon(
                                onPressed: _openAutoDj,
                                icon: const Icon(Icons.queue_play_next),
                                label: const Text('Auto DJ'),
                              ),
                      ),
                    ),
                  ),
                  if (MixRecorder.supported)
                    _RecordButton(
                        recorder: _recorder, onPressed: _toggleRecording),
                  IconButton(
                    tooltip: 'Atajos de teclado: qué tecla hace cada cosa'
                        '${djShortcutHint(DjCommand.help)}',
                    onPressed: () => DjShortcutsDialog.show(context),
                    icon: const Icon(Icons.keyboard),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 12, left: 4),
                    child: Tooltip(
                      message: 'Gestor de archivos: canciones MP3 y WAV de '
                          'cualquier disco${djShortcutHint(DjCommand.files)}',
                      child: FilledButton.tonalIcon(
                        onPressed: () => _openLibrary(null),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Archivos'),
                      ),
                    ),
                  ),
                ],
              ),
              body: LayoutBuilder(builder: (context, constraints) {
                final content = Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    children: [
                      SizedBox(
                        height: 150,
                        child: DjPanel(
                          padding: EdgeInsets.zero,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Column(
                              children: [
                                Expanded(
                                  child: DjScrollingWaveform(
                                      deck: _mixer.a,
                                      frame: _frame,
                                      flip: true),
                                ),
                                Container(height: 1, color: DjColors.border),
                                // Las dos crecen hacia arriba desde su
                                // base: los picos quedan a la vista para
                                // compararlos al mezclar.
                                Expanded(
                                  child: DjScrollingWaveform(
                                      deck: _mixer.b,
                                      frame: _frame,
                                      flip: true),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Expanded(
                        flex: 7,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: _DeckView(
                                deck: _mixer.a,
                                mode: _padModes[0],
                                mixer: _mixer,
                                onOpenLibrary: _openLibrary,
                                frame: _frame,
                                slow: _slow,
                                onMessage: _say,
                              ),
                            ),
                            const SizedBox(width: 6),
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOut,
                              width: _mixerOpen ? 250 : 64,
                              // El contenido se arma a su ancho final y se
                              // recorta mientras se anima (si no, desborda).
                              child: ClipRect(
                                child: OverflowBox(
                                  alignment: Alignment.centerLeft,
                                  minWidth: _mixerOpen ? 250 : 64,
                                  maxWidth: _mixerOpen ? 250 : 64,
                                  child: _mixerOpen
                                      ? _MixerView(
                                          mixer: _mixer,
                                          onEqualizer: _openEqualizer,
                                          mixBeats: _mixBeats,
                                          frame: _frame,
                                          onMessage: _say,
                                          onCollapse: _toggleMixer,
                                        )
                                      : _MixerCollapsed(
                                          mixer: _mixer,
                                          frame: _frame,
                                          onExpand: _toggleMixer,
                                        ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: _DeckView(
                                deck: _mixer.b,
                                mode: _padModes[1],
                                mixer: _mixer,
                                onOpenLibrary: _openLibrary,
                                frame: _frame,
                                slow: _slow,
                                onMessage: _say,
                                mirrored: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
                // Ventanas bajas: se desplaza en vez de apretar todo.
                if (constraints.maxHeight >= 620) return content;
                return SingleChildScrollView(
                  child: SizedBox(height: 620, child: content),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

/// Botón "Grabar mezcla": rojo apagado; grabando, lleno, con el tiempo y
/// un vúmetro chiquito de lo que entra.
class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.recorder, required this.onPressed});

  final MixRecorder recorder;
  final VoidCallback onPressed;

  static const _red = Color(0xFFFF3B3B);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: recorder,
      builder: (context, _) {
        final on = recorder.recording;
        final hint = djShortcutHint(DjCommand.record);
        return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Tooltip(
            message: on
                ? 'Terminar la grabación y guardarla$hint'
                : 'Grabar la mezcla: graba solo lo que sale por los '
                    'parlantes de la computadora, en estéreo (deck A a la '
                    'izquierda, B a la derecha), a un WAV en '
                    'Música\\TK Music\\Mezclas$hint',
            child: OutlinedButton.icon(
              onPressed: recorder.busy ? null : onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: on ? Colors.white : _red,
                backgroundColor: on ? _red.withValues(alpha: 0.85) : null,
                side: BorderSide(color: _red.withValues(alpha: 0.8)),
              ),
              icon: Icon(on ? Icons.stop : Icons.fiber_manual_record, size: 18),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    on
                        ? formatRecordingTime(recorder.elapsed)
                        : 'Grabar mezcla',
                    style: const TextStyle(
                        fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                  if (on) ...[
                    const SizedBox(width: 8),
                    Tooltip(
                      message: recorder.peak >= 1
                          ? 'Satura: bajá el GENERAL o la GANANCIA'
                          : 'Nivel de lo que se graba',
                      child: Container(
                        width: 36,
                        height: 6,
                        decoration: BoxDecoration(
                          color: Colors.black38,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: recorder.peak.clamp(0.02, 1.0),
                          child: Container(
                            decoration: BoxDecoration(
                              color: recorder.peak >= 1
                                  ? Colors.yellowAccent
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Deck
// ---------------------------------------------------------------------------

enum _PadMode { hotCue, loop, jump }

/// Un pad de abajo del deck: lo usan los botones y el teclado.
class _PadSpec {
  const _PadSpec({
    required this.label,
    required this.color,
    this.active = false,
    this.tooltip,
    this.onTap,
    this.onSecondary,
  });

  final String label;
  final Color color;
  final bool active;
  final String? tooltip;
  final VoidCallback? onTap;
  final VoidCallback? onSecondary;
}

int _deckIndex(DjDeck deck) => deck.label == 'A' ? 0 : 1;

/// Los 8 pads de [deck] en el modo [mode].
List<_PadSpec> _padSpecs(DjDeck deck, _PadMode mode) {
  final loaded = deck.loaded;
  final d = _deckIndex(deck);
  String hint(int i) => djShortcutHint(DjCommand.pad, deck: d, arg: i);
  final pads = <_PadSpec>[];
  switch (mode) {
    case _PadMode.hotCue:
      for (var i = 0; i < 8; i++) {
        final set = deck.hotCues[i] != null;
        pads.add(_PadSpec(
          label: '${i + 1}',
          color: DjColors.hotCues[i],
          active: set,
          tooltip: set
              ? 'Saltar al punto ${i + 1} (clic derecho: borrar)${hint(i)}'
              : 'Guardar el punto ${i + 1} acá${hint(i)}',
          onTap: loaded ? () => deck.hotCue(i) : null,
          onSecondary: set ? () => deck.clearHotCue(i) : null,
        ));
      }
    case _PadMode.loop:
      final beats = deck.loop?.beats;
      const sizes = [1.0, 2.0, 4.0, 8.0, 16.0];
      for (var i = 0; i < sizes.length; i++) {
        final b = sizes[i];
        pads.add(_PadSpec(
          label: '${b.toInt()}',
          color: DjColors.loop,
          active: beats == b,
          tooltip: 'Bucle de ${b.toInt()} '
              '${b == 1 ? 'pulso' : 'pulsos'}${hint(i)}',
          onTap: loaded ? () => deck.toggleLoop(b) : null,
        ));
      }
      pads
        ..add(_PadSpec(
          label: 'AUTO',
          color: DjColors.loop,
          active: deck.loop != null,
          tooltip: 'Bucle automático: busca una parte pareja cerca '
              '(4 pulsos → 8 → 16 → apagado)${hint(5)}',
          onTap: loaded ? deck.autoLoop : null,
        ))
        ..add(_PadSpec(
          label: '½',
          color: DjColors.loop,
          tooltip: 'Bucle a la mitad${hint(6)}',
          onTap: deck.loop != null ? deck.halveLoop : null,
        ))
        ..add(_PadSpec(
          label: '×2',
          color: DjColors.loop,
          tooltip: 'Bucle al doble${hint(7)}',
          onTap: deck.loop != null ? deck.doubleLoop : null,
        ));
    case _PadMode.jump:
      const jumps = [-16.0, -8.0, -4.0, -1.0, 1.0, 4.0, 8.0, 16.0];
      for (var i = 0; i < jumps.length; i++) {
        final b = jumps[i];
        pads.add(_PadSpec(
          label: b > 0 ? '+${b.toInt()}' : '${b.toInt()}',
          color: const Color(0xFF20C6E6),
          tooltip: 'Saltar ${b.abs().toInt()} '
              '${b.abs() == 1 ? 'pulso' : 'pulsos'} '
              '${b > 0 ? 'adelante' : 'atrás'}${hint(i)}',
          onTap: loaded ? () => deck.beatJump(b) : null,
        ));
      }
  }
  return pads;
}

class _DeckView extends StatefulWidget {
  const _DeckView({
    required this.deck,
    required this.mode,
    required this.mixer,
    required this.onOpenLibrary,
    required this.frame,
    required this.slow,
    required this.onMessage,
    this.mirrored = false,
  });

  final DjDeck deck;
  final ValueNotifier<_PadMode> mode;
  final DjMixer mixer;
  final ValueChanged<DjDeck> onOpenLibrary;
  final Listenable frame;
  final Listenable slow;
  final ValueChanged<String?> onMessage;

  /// El deck B tiene el pitch del lado de afuera, como en un controlador.
  final bool mirrored;

  @override
  State<_DeckView> createState() => _DeckViewState();
}

class _DeckViewState extends State<_DeckView> {
  _PadMode get _mode => widget.mode.value;

  DjDeck get deck => widget.deck;
  int get _index => _deckIndex(deck);
  String _hint(DjCommand command) => djShortcutHint(command, deck: _index);
  Color get color => DjColors.forDeck(deck.label);

  bool get _synced {
    final other = widget.mixer.other(deck);
    final mine = deck.bpm;
    final theirs = other.bpm;
    if (mine == null || theirs == null) return false;
    final f = deck.features!;
    final target = tempoForSync(f.bpm, theirs);
    return (deck.tempo - target).abs() < 0.001;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([deck, widget.mixer, widget.mode]),
      builder: (context, _) {
        final pitchColumn = _PitchColumn(deck: deck, color: color);
        final jog = Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: DjJogWheel(deck: deck, frame: widget.frame),
          ),
        );
        return DjPanel(
          accent: color,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DeckHeader(
                deck: deck,
                slow: widget.slow,
                mixer: widget.mixer,
                onOpenLibrary: () => widget.onOpenLibrary(deck),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 30,
                child: DjOverview(deck: deck, frame: widget.frame),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: Row(
                  children: widget.mirrored
                      ? [pitchColumn, const SizedBox(width: 6), jog]
                      : [jog, const SizedBox(width: 6), pitchColumn],
                ),
              ),
              const SizedBox(height: 4),
              _transport(),
              const SizedBox(height: 6),
              _padTabs(),
              const SizedBox(height: 4),
              _pads(),
            ],
          ),
        );
      },
    );
  }

  Widget _transport() {
    final loaded = deck.loaded;
    Widget pad(Widget child) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: SizedBox(height: 40, child: child),
          ),
        );
    return Row(
      children: [
        pad(DjPad(
          label: 'CUE',
          color: DjColors.cue,
          active: loaded &&
              !deck.playing &&
              deck.cueMs != null &&
              (deck.positionMs - deck.cueMs!).abs() < 30,
          tooltip: 'Sonando: vuelve al punto de inicio (cue) y frena. '
              'Frenado: lo marca en el pulso más cercano.'
              '${_hint(DjCommand.cue)}',
          onTap: loaded ? deck.cue : null,
        )),
        pad(DjPad(
          label: 'PLAY',
          icon: deck.playing ? Icons.pause : Icons.play_arrow,
          color: const Color(0xFF3DDC84),
          active: deck.playing,
          tooltip: 'Arrancar o frenar${_hint(DjCommand.play)}',
          onTap: loaded ? deck.togglePlay : null,
        )),
        pad(DjPad(
          label: 'SYNC',
          color: color,
          active: _synced,
          tooltip: 'Iguala el BPM y alinea los pulsos con el otro deck'
              '${_hint(DjCommand.sync)}',
          onTap: loaded
              ? () async => widget.onMessage(await widget.mixer.sync(deck))
              : null,
        )),
        pad(DjPad(
          label: 'AUTO',
          color: color,
          active: deck.autoSync,
          tooltip: 'Sincronía automática: sigue solo el tempo y los pulsos '
              'del otro deck, sin desfasarse${_hint(DjCommand.autoSync)}',
          onTap: loaded
              ? () async => widget.onMessage(
                  await widget.mixer.setAutoSync(deck, !deck.autoSync))
              : null,
        )),
        pad(DjPad(
          label: 'TONO',
          color: const Color(0xFFB45CFF),
          active: deck.keyShift != 0,
          tooltip: 'Sincronizar la tonalidad con el otro deck (clic '
              'derecho: tonalidad original)${_hint(DjCommand.keySync)}',
          onTap: loaded
              ? () async => widget.onMessage(await widget.mixer.syncKey(deck))
              : null,
          onSecondary: loaded ? () => deck.setKeyShift(0) : null,
        )),
      ],
    );
  }

  Widget _padTabs() {
    Widget tab(_PadMode mode, String text) {
      final selected = _mode == mode;
      return Expanded(
        child: InkWell(
          onTap: () => widget.mode.value = mode,
          child: Container(
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: selected ? color : DjColors.border,
                  width: selected ? 2 : 1,
                ),
              ),
            ),
            child: Text(
              text,
              style: TextStyle(
                color: selected ? DjColors.text : DjColors.muted,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
          ),
        ),
      );
    }

    return Tooltip(
      message: 'Modo de los pads${_hint(DjCommand.padMode)}',
      waitDuration: const Duration(milliseconds: 800),
      child: Row(children: [
        tab(_PadMode.hotCue, 'PUNTOS'),
        tab(_PadMode.loop, 'BUCLE'),
        tab(_PadMode.jump, 'SALTO'),
      ]),
    );
  }

  Widget _pads() {
    final pads = [
      for (final p in _padSpecs(deck, _mode))
        DjPad(
          label: p.label,
          color: p.color,
          active: p.active,
          tooltip: p.tooltip,
          onTap: p.onTap,
          onSecondary: p.onSecondary,
        ),
    ];
    return Column(
      children: [
        for (var row = 0; row < 2; row++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                for (var i = row * 4; i < row * 4 + 4; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: SizedBox(height: 34, child: pads[i]),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DeckHeader extends StatelessWidget {
  const _DeckHeader({
    required this.deck,
    required this.slow,
    required this.mixer,
    required this.onOpenLibrary,
  });

  final DjDeck deck;
  final Listenable slow;
  final DjMixer mixer;
  final VoidCallback onOpenLibrary;

  static String _camelot(int? key) => key == null
      ? '—'
      : TrackFeatures(bpm: 0, firstBeatMs: 0, keyIndex: key, energy: 0)
              .camelot ??
          '—';

  @override
  Widget build(BuildContext context) {
    final color = DjColors.forDeck(deck.label);
    final song = deck.song;
    return ListenableBuilder(
      listenable: slow,
      builder: (context, _) {
        final bpm = deck.bpm;
        final pos = deck.positionMs;
        final remaining = math.max(0.0, deck.durationMs - pos);
        final isMaster = identical(mixer.masterDeck, deck);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(deck.label,
                            style: const TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.w900)),
                      ),
                      const SizedBox(width: 6),
                      // Lado fijo de salida y prueba: tres pitidos por ese
                      // lado.
                      Tooltip(
                        message: 'Probar salida: suena un pitido solo por el '
                            'lado ${deck.label == 'A' ? 'izquierdo' : 'derecho'}'
                            ' (el deck ${deck.label} sale en mono por ahí)'
                            '${djShortcutHint(DjCommand.testOutput, deck: _deckIndex(deck))}',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: () => mixer.testOutput(deck),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                  color: color.withValues(alpha: 0.6)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.volume_up, size: 12, color: color),
                                const SizedBox(width: 3),
                                Text(deck.sideLabel,
                                    style: TextStyle(
                                        color: color,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800)),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        height: 22,
                        child: DjPad(
                          label: 'CARGAR',
                          color: color,
                          dense: true,
                          tooltip: 'Elegir una canción para el deck '
                              '${deck.label}${djShortcutHint(DjCommand.load, deck: _deckIndex(deck))}',
                          onTap: onOpenLibrary,
                        ),
                      ),
                      if (isMaster) ...[
                        const SizedBox(width: 6),
                        const Text('MAESTRO',
                            style: TextStyle(
                                color: DjColors.cue,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1)),
                      ],
                      if (deck.analyzing || deck.loadingWaveform) ...[
                        const SizedBox(width: 6),
                        const SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(strokeWidth: 1.5)),
                        const SizedBox(width: 4),
                        Text(
                            deck.analyzing ? 'analizando BPM' : 'cargando onda',
                            style: const TextStyle(
                                color: DjColors.muted, fontSize: 10)),
                      ] else if (deck.analysisFailed) ...[
                        const SizedBox(width: 6),
                        InkWell(
                          onTap: deck.retryAnalysis,
                          child: const Text('sin BPM · reintentar',
                              style: TextStyle(
                                  color: DjColors.cue,
                                  fontSize: 10,
                                  decoration: TextDecoration.underline,
                                  decorationColor: DjColors.cue)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (song == null)
                    InkWell(
                      onTap: onOpenLibrary,
                      child: Text(
                        'Tocá para elegir una canción',
                        style: TextStyle(
                            color: color,
                            fontSize: 15,
                            fontWeight: FontWeight.w700),
                      ),
                    )
                  else
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: DjColors.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w700),
                    ),
                  Text(
                    song?.artist ?? ' ',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: DjColors.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song == null
                        ? ' '
                        : '${formatDjTime(pos)}   -${formatDjTime(remaining)}',
                    style: const TextStyle(
                      color: DjColors.text,
                      fontSize: 13,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  bpm == null ? '---.--' : bpm.toStringAsFixed(2),
                  style: TextStyle(
                    color: color,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const Text('BPM',
                    style: TextStyle(
                        color: DjColors.muted,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1)),
                const SizedBox(height: 2),
                Text(
                  'TONO ${_camelot(deck.effectiveKey)}'
                  '${deck.keyShift != 0 ? ' (${deck.keyShift > 0 ? '+' : ''}${deck.keyShift})' : ''}',
                  style: const TextStyle(
                      color: Color(0xFFB45CFF),
                      fontSize: 12,
                      fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _PitchColumn extends StatelessWidget {
  const _PitchColumn({required this.deck, required this.color});

  final DjDeck deck;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final pct = deck.pitch * 100;
    return SizedBox(
      width: 64,
      child: Column(
        children: [
          SizedBox(
            height: 24,
            child: Row(
              children: [
                Expanded(
                  child: DjPad(
                    label: '±${(deck.range * 100).round()}',
                    color: DjColors.muted,
                    dense: true,
                    tooltip: 'Rango del pitch (±8, ±16, ±32 %)'
                        '${djShortcutHint(DjCommand.pitchRange, deck: _deckIndex(deck))}',
                    onTap: () {
                      final i = djPitchRanges.indexOf(deck.range);
                      deck.setRange(
                          djPitchRanges[(i + 1) % djPitchRanges.length]);
                    },
                  ),
                ),
                const SizedBox(width: 3),
                Expanded(
                  child: DjPad(
                    label: 'FIJO',
                    icon: deck.keylock ? Icons.lock : Icons.lock_open,
                    color: DjColors.cue,
                    active: deck.keylock,
                    dense: true,
                    tooltip: 'Tono fijo: la voz no se pone aguda ni grave al '
                        'cambiar el tempo'
                        '${djShortcutHint(DjCommand.keylock, deck: _deckIndex(deck))}',
                    onTap: () => deck.setKeylock(!deck.keylock),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Tooltip(
              message: 'Pitch: velocidad de la canción (doble clic: 0 %). '
                  'Teclas: ${deck.label == 'A' ? 'A / S, D a 0' : 'H / J, K a 0'}',
              child: DjVerticalFader(
                value: deck.pitch,
                min: -deck.range,
                max: deck.range,
                color: color,
                inverted: true,
                onChanged: deck.setPitch,
                onDoubleTap: () => deck.setPitch(0),
              ),
            ),
          ),
          Text(
            '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(2)}%',
            style: const TextStyle(
              color: DjColors.text,
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 24,
                  child: DjPad(
                    label: 'b',
                    color: const Color(0xFFB45CFF),
                    dense: true,
                    tooltip: 'Bajar un semitono'
                        '${djShortcutHint(DjCommand.semitoneDown, deck: _deckIndex(deck))}',
                    onTap: deck.loaded
                        ? () => deck.setKeyShift(deck.keyShift - 1)
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 3),
              Expanded(
                child: SizedBox(
                  height: 24,
                  child: DjPad(
                    label: '#',
                    color: const Color(0xFFB45CFF),
                    dense: true,
                    tooltip: 'Subir un semitono'
                        '${djShortcutHint(DjCommand.semitoneUp, deck: _deckIndex(deck))}',
                    onTap: deck.loaded
                        ? () => deck.setKeyShift(deck.keyShift + 1)
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mezclador
// ---------------------------------------------------------------------------

class _MixerView extends StatefulWidget {
  const _MixerView({
    required this.mixer,
    required this.onEqualizer,
    required this.mixBeats,
    required this.frame,
    required this.onMessage,
    required this.onCollapse,
  });

  final DjMixer mixer;
  final VoidCallback onEqualizer;
  final ValueNotifier<int> mixBeats;
  final Listenable frame;
  final ValueChanged<String?> onMessage;
  final VoidCallback onCollapse;

  @override
  State<_MixerView> createState() => _MixerViewState();
}

class _MixerViewState extends State<_MixerView> {
  int get _mixBeats => widget.mixBeats.value;

  @override
  Widget build(BuildContext context) {
    final mixer = widget.mixer;
    return ListenableBuilder(
      listenable: Listenable.merge([mixer, mixer.a, mixer.b, widget.mixBeats]),
      builder: (context, _) {
        return DjPanel(
          child: Column(
            children: [
              SizedBox(
                height: 24,
                child: Row(
                  children: [
                    const Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Text('MEZCLADOR',
                            style: TextStyle(
                                color: DjColors.muted,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2)),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Plegar el mezclador'
                          '${djShortcutHint(DjCommand.toggleMixer)}',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      iconSize: 18,
                      onPressed: widget.onCollapse,
                      icon: const Icon(Icons.unfold_less_double,
                          color: DjColors.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 2),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _ChannelStrip(deck: mixer.a, frame: widget.frame),
                    ),
                    Container(width: 1, color: DjColors.border),
                    Expanded(
                      child: _ChannelStrip(deck: mixer.b, frame: widget.frame),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 30,
                width: double.infinity,
                child: DjPad(
                  label: 'ECUALIZADOR',
                  color: DjColors.text,
                  dense: true,
                  tooltip: 'Ganancia, agudos, medios y graves de los dos decks'
                      '${djShortcutHint(DjCommand.equalizer)}',
                  onTap: widget.onEqualizer,
                ),
              ),
              const SizedBox(height: 4),
              Tooltip(
                message: 'Volumen general: hasta +6 dB para potenciar. '
                    'Doble clic: 0 dB. Teclas: ↑ ↓',
                child: DjKnob(
                  value: mixer.master,
                  min: 0,
                  max: DjMixer.maxMaster,
                  center: 1.0,
                  label: mixer.master > 1.005
                      ? 'GENERAL +${(20 * math.log(mixer.master) / math.ln10).toStringAsFixed(1)} dB'
                      : 'GENERAL',
                  color: mixer.master > 1.005 ? DjColors.cue : DjColors.text,
                  size: 40,
                  onChanged: mixer.setMaster,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Text('A',
                      style: TextStyle(
                          color: DjColors.deckA, fontWeight: FontWeight.w900)),
                  Expanded(
                    child: Tooltip(
                      message: 'Crossfader: de un deck al otro. Teclas: ← → '
                          '(Shift: al extremo, Espacio: al centro)',
                      waitDuration: const Duration(milliseconds: 800),
                      child: DjCrossfader(
                        value: mixer.crossfader,
                        onChanged: (v) {
                          if (mixer.mixingTo != null) mixer.cancelAutoMix();
                          mixer.setCrossfader(v);
                        },
                      ),
                    ),
                  ),
                  const Text('B',
                      style: TextStyle(
                          color: DjColors.deckB, fontWeight: FontWeight.w900)),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  for (final beats in [8, 16, 32])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: SizedBox(
                          height: 22,
                          child: DjPad(
                            label: '$beats',
                            color: DjColors.muted,
                            dense: true,
                            active: _mixBeats == beats,
                            tooltip: 'Mezcla automática en $beats pulsos'
                                '${djShortcutHint(DjCommand.mixBeats, arg: beats)}',
                            onTap: () => widget.mixBeats.value = beats,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 36,
                width: double.infinity,
                child: DjPad(
                  label: mixer.mixingTo != null
                      ? 'MEZCLANDO → ${mixer.mixingTo!.label}'
                      : 'MEZCLA AUTO',
                  color: DjColors.cue,
                  active: mixer.mixingTo != null,
                  tooltip: 'Pasa al otro deck en $_mixBeats pulsos: lo '
                      'sincroniza, lo arranca en el próximo compás y mueve '
                      'el crossfader solo${djShortcutHint(DjCommand.autoMix)}',
                  onTap: () async =>
                      widget.onMessage(await mixer.autoMix(beats: _mixBeats)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// El mezclador plegado: una columna angosta con los vúmetros y el
/// crossfader (vertical: A arriba, B abajo). Tocar arriba lo despliega.
class _MixerCollapsed extends StatelessWidget {
  const _MixerCollapsed({
    required this.mixer,
    required this.frame,
    required this.onExpand,
  });

  final DjMixer mixer;
  final Listenable frame;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: mixer,
      builder: (context, _) => DjPanel(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Column(
          children: [
            IconButton(
              tooltip: 'Desplegar el mezclador'
                  '${djShortcutHint(DjCommand.toggleMixer)}',
              visualDensity: VisualDensity.compact,
              onPressed: onExpand,
              icon: const Icon(Icons.unfold_more_double,
                  color: DjColors.muted, size: 20),
            ),
            const RotatedBox(
              quarterTurns: 1,
              child: Text('MEZCLADOR',
                  style: TextStyle(
                      color: DjColors.muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 3)),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final deck in mixer.decks)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: SizedBox(
                        width: 8,
                        child: CustomPaint(
                          painter: _VuPainter(deck: deck, repaint: frame),
                          size: Size.infinite,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Text('A',
                style: TextStyle(
                    color: DjColors.deckA, fontWeight: FontWeight.w900)),
            SizedBox(
              height: 130,
              width: 44,
              child: RotatedBox(
                quarterTurns: 1,
                child: DjCrossfader(
                  value: mixer.crossfader,
                  onChanged: (v) {
                    if (mixer.mixingTo != null) mixer.cancelAutoMix();
                    mixer.setCrossfader(v);
                  },
                ),
              ),
            ),
            const Text('B',
                style: TextStyle(
                    color: DjColors.deckB, fontWeight: FontWeight.w900)),
          ],
        ),
      ),
    );
  }
}

/// Un canal del mezclador: vúmetro y fader. La ganancia y el ecualizador
/// están en su propia ventana ([_EqualizerDialog]).
class _ChannelStrip extends StatelessWidget {
  const _ChannelStrip({required this.deck, required this.frame});

  final DjDeck deck;
  final Listenable frame;

  @override
  Widget build(BuildContext context) {
    final color = DjColors.forDeck(deck.label);
    final touched = deck.gainDb.abs() > 0.05 || deck.eq.any((v) => v != 0);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(deck.label,
                style: TextStyle(color: color, fontWeight: FontWeight.w900)),
            if (touched)
              const Tooltip(
                message: 'Este canal tiene ganancia o ecualizador movidos',
                child: Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Icon(Icons.tune, size: 12, color: DjColors.cue),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 8,
                child: CustomPaint(
                  painter: _VuPainter(deck: deck, repaint: frame),
                  size: Size.infinite,
                ),
              ),
              SizedBox(
                width: 40,
                child: DjVerticalFader(
                  value: deck.volume,
                  min: 0,
                  max: 1,
                  color: color,
                  onChanged: deck.setVolume,
                  onDoubleTap: () => deck.setVolume(0.8),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Ventana del ecualizador: ganancia, agudos, medios y graves de los dos
/// decks, uno al lado del otro. Se mueve en vivo (se escucha mientras se
/// gira).
class _EqualizerDialog extends StatelessWidget {
  const _EqualizerDialog({required this.mixer});

  final DjMixer mixer;

  Widget _deckColumn(DjDeck deck) {
    final color = DjColors.forDeck(deck.label);
    const labels = ['AGUDOS', 'MEDIOS', 'GRAVES'];
    const bands = [2, 1, 0];
    final boosted = deck.gainDb > 0.05;
    return Expanded(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('DECK ${deck.label}',
                style: const TextStyle(
                    color: Colors.black, fontWeight: FontWeight.w900)),
          ),
          const SizedBox(height: 4),
          Text(deck.song?.title ?? 'Sin canción',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: DjColors.muted, fontSize: 12)),
          const SizedBox(height: 12),
          Tooltip(
            message: 'GANANCIA (potenciador): sube o baja el volumen de este '
                'deck de -12 a +12 dB.',
            child: DjKnob(
              value: deck.gainDb,
              min: -DjDeck.maxGainDb,
              max: DjDeck.maxGainDb,
              label: boosted
                  ? 'GANANCIA +${deck.gainDb.toStringAsFixed(1)} dB'
                  : 'GANANCIA ${deck.gainDb.toStringAsFixed(1)} dB',
              color: boosted ? DjColors.cue : color,
              size: 64,
              onChanged: deck.setGain,
            ),
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: DjKnob(
                value: deck.eq[bands[i]],
                min: DjDeck.eqKill,
                max: 6,
                label:
                    '${labels[i]} ${deck.eq[bands[i]] <= DjDeck.eqKill + 0.1 ? 'KILL' : '${deck.eq[bands[i]] > 0 ? '+' : ''}${deck.eq[bands[i]].toStringAsFixed(1)} dB'}',
                color: color,
                size: 64,
                onChanged: (v) => deck.setEq(bands[i], v),
              ),
            ),
          TextButton.icon(
            onPressed: () async {
              await deck.setGain(0);
              for (final band in [0, 1, 2]) {
                await deck.setEq(band, 0);
              }
            },
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('Centrar todo'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: DjColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: DjColors.border),
      ),
      child: SizedBox(
        width: 560,
        child: ListenableBuilder(
          listenable: Listenable.merge([mixer.a, mixer.b]),
          builder: (context, _) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.tune, color: DjColors.text),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text('Ecualizador',
                          style: TextStyle(
                              color: DjColors.text,
                              fontSize: 18,
                              fontWeight: FontWeight.w800)),
                    ),
                    IconButton(
                      tooltip: 'Cerrar',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, color: DjColors.muted),
                    ),
                  ],
                ),
                const Text(
                  'Las perillas arrancan al medio (0 dB) y se enganchan ahí al '
                  'girarlas. Todo a la izquierda es "kill": esa banda se '
                  'apaga.',
                  style: TextStyle(color: DjColors.muted, fontSize: 12),
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _deckColumn(mixer.a),
                    Container(width: 1, height: 420, color: DjColors.border),
                    _deckColumn(mixer.b),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Ventana del Auto DJ: la lista (se reordena arrastrando), qué suena y qué
/// sigue, y los controles para arrancarlo, mezclar ya o sumar canciones.
class _AutoDjDialog extends StatelessWidget {
  const _AutoDjDialog({
    required this.autoDj,
    required this.mixBeats,
    required this.onAddFromFiles,
    required this.onAddPlaylist,
    required this.onMessage,
  });

  final DjAutoDj autoDj;
  final ValueNotifier<int> mixBeats;
  final Future<void> Function(BuildContext context) onAddFromFiles;
  final Future<void> Function(BuildContext context) onAddPlaylist;
  final ValueChanged<String?> onMessage;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: DjColors.panel,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: DjColors.border),
      ),
      child: SizedBox(
        width: math.min(760, size.width - 48),
        height: math.min(720, size.height - 48),
        child: ListenableBuilder(
          listenable: Listenable.merge([autoDj, mixBeats]),
          builder: (context, _) {
            final pending = autoDj.items.where((i) => !i.played).length;
            final next = autoDj.next;
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.queue_play_next, color: DjColors.text),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text('Auto DJ',
                            style: TextStyle(
                                color: DjColors.text,
                                fontSize: 18,
                                fontWeight: FontWeight.w800)),
                      ),
                      IconButton(
                        tooltip: 'Cerrar (el Auto DJ sigue)',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close, color: DjColors.muted),
                      ),
                    ],
                  ),
                  const Text(
                    'Armá una lista y el Modo DJ la hace sonar sola: carga la '
                    'siguiente en el deck libre y, cuando a la que suena le '
                    'queda lo justo, la mezcla sincronizada en el próximo '
                    'compás. Podés seguir tocando los decks mientras tanto.',
                    style: TextStyle(color: DjColors.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (autoDj.running)
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFD9443B)),
                          onPressed: autoDj.stop,
                          icon: const Icon(Icons.stop),
                          label: const Text('Detener Auto DJ'),
                        )
                      else
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                              backgroundColor: DjColors.loop,
                              foregroundColor: Colors.black),
                          onPressed: pending == 0
                              ? null
                              : () async => onMessage(await autoDj.start()),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Arrancar Auto DJ'),
                        ),
                      OutlinedButton.icon(
                        onPressed: autoDj.running && !autoDj.mixing
                            ? autoDj.mixNow
                            : null,
                        icon: const Icon(Icons.skip_next),
                        label: const Text('Mezclar ya'),
                      ),
                      const Text('Mezcla en',
                          style: TextStyle(color: DjColors.muted)),
                      for (final beats in [8, 16, 32])
                        ChoiceChip(
                          label: Text('$beats pulsos'),
                          selected: mixBeats.value == beats,
                          onSelected: (_) => mixBeats.value = beats,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    autoDj.mixing
                        ? 'Mezclando con "${autoDj.loadedNext?.song.title ?? next?.song.title ?? ''}"…'
                        : autoDj.running
                            ? next == null
                                ? 'Suena la última de la lista.'
                                : 'Sigue: "${next.song.title}" '
                                    '${autoDj.loadedNext == next ? '(ya cargada en el deck libre)' : '(se carga cuando el deck se libere)'}'
                            : autoDj.message ??
                                '$pending por sonar de ${autoDj.items.length}.',
                    style: TextStyle(
                        color: autoDj.running ? DjColors.loop : DjColors.text,
                        fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 4,
                          children: [
                            TextButton.icon(
                              onPressed: () => onAddFromFiles(context),
                              icon: const Icon(Icons.folder_open, size: 18),
                              label: const Text('Agregar desde Archivos'),
                            ),
                            TextButton.icon(
                              onPressed: () => onAddPlaylist(context),
                              icon: const Icon(Icons.queue_music, size: 18),
                              label: const Text('Agregar una lista guardada'),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Más opciones',
                        icon:
                            const Icon(Icons.more_vert, color: DjColors.muted),
                        onSelected: (value) async {
                          switch (value) {
                            case 'order':
                              onMessage('Ordenando por ritmo y tonalidad…');
                              await autoDj.smartOrder();
                              onMessage('Lista ordenada para mezclar.');
                            case 'reset':
                              autoDj.resetPlayed();
                            case 'clear':
                              autoDj.clear();
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 'order',
                              child: Text('Orden inteligente (ritmo y '
                                  'tonalidad)')),
                          PopupMenuItem(
                              value: 'reset',
                              child: Text('Volver a marcar todas como '
                                  'pendientes')),
                          PopupMenuItem(
                              value: 'clear', child: Text('Vaciar la lista')),
                        ],
                      ),
                    ],
                  ),
                  const Divider(color: DjColors.border, height: 8),
                  Expanded(
                    child: autoDj.items.isEmpty
                        ? const Center(
                            child: Text(
                              'La lista está vacía: agregá canciones desde '
                              'Archivos o una lista guardada.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: DjColors.muted),
                            ),
                          )
                        : ReorderableListView.builder(
                            buildDefaultDragHandles: false,
                            itemCount: autoDj.items.length,
                            onReorder: (from, to) =>
                                autoDj.move(from, to > from ? to - 1 : to),
                            itemBuilder: (context, index) {
                              final item = autoDj.items[index];
                              final isCurrent = identical(item, autoDj.current);
                              final isNext = identical(item, next);
                              final color = isCurrent
                                  ? DjColors.loop
                                  : isNext
                                      ? DjColors.cue
                                      : item.played
                                          ? DjColors.muted
                                          : DjColors.text;
                              return ListTile(
                                key: ValueKey(item.id),
                                dense: true,
                                leading: ReorderableDragStartListener(
                                  index: index,
                                  child: const Icon(Icons.drag_indicator,
                                      color: DjColors.muted),
                                ),
                                title: Text(item.song.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: color,
                                        fontWeight: isCurrent || isNext
                                            ? FontWeight.w800
                                            : FontWeight.w500)),
                                subtitle: Text(
                                  isCurrent
                                      ? 'Sonando'
                                      : isNext
                                          ? 'Sigue'
                                          : item.played
                                              ? 'Ya sonó'
                                              : (item.song.artist ?? ''),
                                  style: TextStyle(
                                      color: color.withValues(alpha: 0.8),
                                      fontSize: 11),
                                ),
                                trailing: isCurrent
                                    ? const Icon(Icons.graphic_eq,
                                        color: DjColors.loop)
                                    : IconButton(
                                        tooltip: 'Sacar de la lista',
                                        onPressed: () => autoDj.remove(item),
                                        icon: const Icon(Icons.close,
                                            size: 18, color: DjColors.muted),
                                      ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Vúmetro del canal, a partir de la forma de onda en la posición actual.
class _VuPainter extends CustomPainter {
  _VuPainter({required this.deck, required Listenable repaint})
      : super(repaint: repaint);

  final DjDeck deck;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = DjColors.background);
    final peaks = deck.peaks;
    if (!deck.playing ||
        peaks == null ||
        peaks.isEmpty ||
        deck.durationMs <= 0) {
      return;
    }
    final i = (deck.positionMs / deck.durationMs * (peaks.length - 1))
        .round()
        .clamp(0, peaks.length - 1);
    // Nivel real de salida (fader × crossfader × general × ganancia). Por
    // encima de 1 satura: se marca en rojo arriba.
    final raw = peaks[i] * deck.outputLevel;
    final level = raw.clamp(0.0, 1.0);
    const segments = 14;
    if (raw > 1.0) {
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, 6),
          Paint()..color = const Color(0xFFFF1744));
    }
    final segH = size.height / segments;
    for (var s = 0; s < segments; s++) {
      final on = (s + 1) / segments <= level;
      if (!on) continue;
      final fraction = s / segments;
      final color = fraction > 0.85
          ? const Color(0xFFFF3B3B)
          : fraction > 0.65
              ? const Color(0xFFFFC53D)
              : const Color(0xFF3DDC84);
      canvas.drawRect(
        Rect.fromLTWH(
            0, size.height - (s + 1) * segH + 1, size.width, segH - 2),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_VuPainter old) => true;
}
