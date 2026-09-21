import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/domain/entities/song.dart';

import 'audio_handler.dart';
import 'loudness_store.dart';
import 'waveform_store.dart';

enum AutomixStatus { idle, loading, playing, crossfading, finished }

/// Motor del Mezclador automático: mantiene dos reproductores propios
/// (necesita dos para el crossfade) en vez de usar MyAudioHandler
/// directamente. El volumen de cada tema se normaliza según su dB medido
/// ([LoudnessStore]) para que el cruce no se sienta más fuerte ni más flojo
/// de golpe.
///
/// Aun así, mientras suena "toma prestada" la notificación del reproductor
/// principal ([MyAudioHandler.takeExternalControl]) para que la
/// reproducción sobreviva en segundo plano y se vea en la notificación,
/// sin tener que duplicar todo el pipeline de audio_service acá.
class AutomixEngine extends ChangeNotifier {
  AutomixEngine._();

  /// Singleton (como FavoritesStore/PlaylistStore): tiene que sobrevivir a
  /// que se cierre la pantalla del Mezclador automático, si no la mezcla se
  /// cortaría apenas volvés atrás a Biblioteca/Favoritos/etc.
  static final instance = AutomixEngine._();

  final _playerA = AudioPlayer();
  final _playerB = AudioPlayer();
  final _loudness = LoudnessStore();
  final _waveforms = WaveformStore();

  List<Song> _queue = [];
  int _index = -1;
  bool _usingA = true;
  bool _crossfading = false;
  StreamSubscription<Duration>? _positionSub;
  DateTime? _lastReportedAt;

  MyAudioHandler? get _handler =>
      isAudioAvailable ? sl<AudioHandler>() as MyAudioHandler : null;

  /// Onda de la canción que está sonando ahora, para la vista estilo
  /// VirtualDJ. `null` mientras se está analizando (la primera vez; después
  /// queda cacheada en [WaveformStore]).
  List<double>? currentPeaks;

  static const _crossfadeDuration = Duration(seconds: 8);
  // Volumen de referencia (LUFS/dB aproximado) al que se normalizan todas
  // las canciones; -23 es un estándar común de sonoridad de broadcast.
  static const _targetDb = -23.0;
  static const _minGain = 0.25;
  static const _maxGain = 1.4;

  AutomixStatus status = AutomixStatus.idle;

  AudioPlayer get _active => _usingA ? _playerA : _playerB;
  AudioPlayer get _standby => _usingA ? _playerB : _playerA;

  Song? get currentSong =>
      _index >= 0 && _index < _queue.length ? _queue[_index] : null;
  Song? get nextSong =>
      _index + 1 < _queue.length ? _queue[_index + 1] : null;

  /// Canciones después de la que está sonando, en orden. Reordenarla con
  /// [reorderUpcoming] cambia directamente cuál es la próxima en cruzar,
  /// porque [nextSong] siempre lee la posición siguiente a [_index].
  List<Song> get upcomingQueue =>
      _index + 1 < _queue.length ? _queue.sublist(_index + 1) : const [];

  /// [newIndex] ya viene ajustado por el llamador (convención de
  /// [ReorderableListView.onReorder]: si es mayor que [oldIndex], restarle
  /// 1 antes de llamar acá), igual que [MyAudioHandler.moveQueueItem].
  void reorderUpcoming(int oldIndex, int newIndex) {
    final base = _index + 1;
    final from = base + oldIndex;
    if (from < base || from >= _queue.length) return;
    final item = _queue.removeAt(from);
    final to = (base + newIndex).clamp(base, _queue.length);
    _queue.insert(to, item);
    notifyListeners();
  }

  Stream<Duration> get positionStream => _active.positionStream;
  Duration? get duration => _active.duration;
  bool get isPlaying => _active.playing;
  bool get isCrossfading => _crossfading;

  Future<void> start(List<Song> queue) async {
    _queue = queue;
    _index = 0;
    if (_queue.isEmpty) return;

    status = AutomixStatus.loading;
    notifyListeners();

    try {
      await _loadIntoPlayer(_active, _queue[0]);

      _handler?.takeExternalControl(
        onPlay: resumeSession,
        onPause: pauseSession,
        onStop: stop,
        onSkipNext: skipToNext,
      );
      // El volumen normalizado se aplica aparte, sin bloquear el arranque:
      // si el análisis de sonoridad está lento (o tarda su límite de 8s),
      // mejor que suene ya a volumen normal y se ajuste solo al toque que
      // esperar con la pantalla de carga.
      await _active.setVolume(1.0);
      // OJO: el Future de play() de just_audio no se resuelve cuando
      // arranca a sonar, sino cuando la reproducción se DETIENE (pausa o
      // termina) — awaitearlo acá dejaba toda esta función colgada hasta
      // que la canción se acababa sola, con la pantalla pegada en "cargando"
      // todo ese tiempo (aunque el audio sí sonara).
      unawaited(_active.play());

      status = AutomixStatus.playing;
      _reportState();
      unawaited(_loadPeaksForCurrent());
      unawaited(_applyGainWhenReady(_queue[0], _active));
    } catch (_) {
      // El primer archivo falló al cargar: no tiene sentido quedarse en la
      // pantalla de carga para siempre.
      status = AutomixStatus.finished;
    } finally {
      _listenForCrossfade();
      notifyListeners();
    }
  }

  Future<void> _applyGainWhenReady(Song song, AudioPlayer player) async {
    final gain = await _gainFor(song);
    if (currentSong != song) return;
    await player.setVolume(gain);
  }

  /// Empuja el estado actual a la notificación del reproductor principal
  /// (si el Automix tiene su control tomado; si no, no hace nada). No hace
  /// falta llamarlo en cada tick de posición — Android extrapola la barra
  /// de progreso sola a partir de la posición + si está sonando.
  void _reportState({Duration? position}) {
    final song = currentSong;
    if (song == null) return;
    _handler?.reportExternalState(
      title: song.title,
      artist: song.artist,
      filePath: song.filePath,
      mediaStoreId: song.mediaStoreId,
      playing: _active.playing,
      position: position ?? _active.position,
      duration: _active.duration,
    );
  }

  /// Igual que [_reportState] pero sin pisar la notificación más de una
  /// vez cada 10s salvo que sea un cambio real (canción, play/pausa) — se
  /// usa desde el tick de posición normal, que dispara mucho más seguido.
  void _maybeReportState(Duration position) {
    final now = DateTime.now();
    if (_lastReportedAt != null &&
        now.difference(_lastReportedAt!) < const Duration(seconds: 10)) {
      return;
    }
    _lastReportedAt = now;
    _reportState(position: position);
  }

  Future<void> _loadPeaksForCurrent() async {
    final song = currentSong;
    if (song == null) return;
    currentPeaks = null;
    notifyListeners();

    // Arranca a decodificar desde donde ya está el reproductor (no siempre
    // es 0: en el cruce, el activo lleva unos segundos sonando) hacia
    // adelante primero.
    final total = duration ?? Duration.zero;
    final fraction = total.inMilliseconds == 0
        ? 0.0
        : (_active.position.inMilliseconds / total.inMilliseconds)
            .clamp(0.0, 1.0);

    final peaks = await _waveforms.waveformFor(
      mediaStoreId: song.mediaStoreId,
      filePath: song.filePath,
      positionFraction: fraction,
      onProgress: (partial) {
        if (currentSong != song) return;
        currentPeaks = partial;
        notifyListeners();
      },
    );
    if (currentSong != song) return;
    currentPeaks = peaks;
    notifyListeners();
  }

  Future<void> _loadIntoPlayer(AudioPlayer player, Song song) {
    return player.setAudioSource(AudioSource.uri(Uri.file(song.filePath)));
  }

  Future<double> _gainFor(Song song) async {
    final db = await _loudness.dbFor(song);
    final diff = _targetDb - db;
    final gain = pow(10, diff / 20).toDouble();
    return gain.clamp(_minGain, _maxGain);
  }

  void _listenForCrossfade() {
    _positionSub?.cancel();
    _positionSub = _active.positionStream.listen((position) {
      if (_crossfading) return;
      final total = _active.duration;
      if (total == null) return;
      final remaining = total - position;

      if (nextSong != null && remaining <= _crossfadeDuration) {
        _crossfading = true;
        unawaited(_crossfadeToNext());
      } else if (nextSong == null && remaining <= Duration.zero) {
        status = AutomixStatus.finished;
        notifyListeners();
      }

      _maybeReportState(position);
    });
  }

  /// Todo el cuerpo va en try/finally: si algo falla a mitad de camino
  /// (archivo siguiente corrupto, lo que sea) sin esto la bandera
  /// [_crossfading] quedaba trabada en `true` para siempre — y como
  /// [_listenForCrossfade] no dispara un cruce nuevo mientras esté prendida,
  /// la mezcla se congelaba ahí sin pasar nunca a la canción siguiente.
  Future<void> _crossfadeToNext() async {
    final from = currentSong;
    final to = nextSong;
    if (from == null || to == null) {
      _crossfading = false;
      return;
    }

    try {
      final standby = _standby;
      final active = _active;
      await _loadIntoPlayer(standby, to);
      final fromGain = await _gainFor(from);
      final toGain = await _gainFor(to);

      await standby.setVolume(0);
      unawaited(standby.play()); // ver nota sobre play() en start()

      status = AutomixStatus.crossfading;
      notifyListeners();

      const steps = 24;
      final stepDelay =
          Duration(milliseconds: _crossfadeDuration.inMilliseconds ~/ steps);
      for (var i = 1; i <= steps; i++) {
        final t = i / steps;
        await active.setVolume(fromGain * (1 - t));
        await standby.setVolume(toGain * t);
        await Future.delayed(stepDelay);
      }

      await active.stop();
      _usingA = !_usingA;
      _index++;
      status = AutomixStatus.playing;
      _reportState();
      unawaited(_loadPeaksForCurrent());
    } catch (_) {
      // No se pudo cruzar a la siguiente (archivo problemático, etc.): se
      // queda en la que ya estaba sonando en vez de perder toda la sesión.
      status = AutomixStatus.playing;
    } finally {
      _crossfading = false;
      _listenForCrossfade();
      notifyListeners();
    }
  }

  /// Fuerza el paso al siguiente tema ya, sin esperar a que el actual esté
  /// por terminar.
  Future<void> skipToNext() async {
    if (_crossfading || nextSong == null) return;
    _crossfading = true;
    await _crossfadeToNext();
  }

  Future<void> pauseSession() async {
    await _active.pause();
    _reportState();
    notifyListeners();
  }

  Future<void> resumeSession() async {
    unawaited(_active.play()); // ver nota sobre play() en start()
    _reportState();
    notifyListeners();
  }

  Future<void> togglePlayPause() =>
      _active.playing ? pauseSession() : resumeSession();

  Future<void> stop() async {
    await _positionSub?.cancel();
    await _playerA.stop();
    await _playerB.stop();
    status = AutomixStatus.idle;
    _handler?.releaseExternalControl();
    notifyListeners();
  }

  // Sin dispose(): es un singleton igual que FavoritesStore/PlaylistStore,
  // vive todo lo que dure la app. stop() ya deja los reproductores listos
  // para un start() siguiente sin tener que recrearlos.
}
