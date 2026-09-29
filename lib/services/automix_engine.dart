import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/domain/entities/song.dart';

import 'app_audio_handler.dart';
import 'basic_player.dart';
import 'crossfade_coordinator.dart';
import 'loudness_store.dart';
import 'track_features.dart';
import 'track_features_store.dart';
import 'waveform_store.dart';

enum AutomixStatus { idle, analyzing, loading, playing, crossfading, finished }

/// Motor del Mezclador automático: mantiene dos reproductores propios
/// (necesita dos para el crossfade) en vez de usar el reproductor principal
/// directamente — just_audio en Android, media_kit en desktop, vía
/// [BasicPlayer]. El volumen de cada tema se normaliza según su dB medido
/// ([LoudnessStore]) para que el cruce no se sienta más fuerte ni más flojo
/// de golpe.
///
/// Aun así, mientras suena "toma prestada" la notificación del reproductor
/// principal ([AppAudioHandler.takeExternalControl]) para que la
/// reproducción sobreviva en segundo plano y se vea en la notificación (o
/// en los controles multimedia de Windows), sin tener que duplicar todo el
/// pipeline de audio_service acá.
class AutomixEngine extends ChangeNotifier {
  AutomixEngine._();

  /// Singleton (como FavoritesStore/PlaylistStore): tiene que sobrevivir a
  /// que se cierre la pantalla del Mezclador automático, si no la mezcla se
  /// cortaría apenas volvés atrás a Biblioteca/Favoritos/etc.
  static final instance = AutomixEngine._();

  final _playerA = BasicPlayer();
  final _playerB = BasicPlayer();
  final _loudness = LoudnessStore();
  final _waveforms = WaveformStore();

  List<Song> _queue = [];
  int _index = -1;
  bool _usingA = true;
  bool _crossfading = false;
  StreamSubscription<Duration>? _positionSub;
  DateTime? _lastReportedAt;

  AppAudioHandler? get _handler =>
      isAudioAvailable ? sl<AudioHandler>() as AppAudioHandler : null;

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

  /// Mientras se analiza el ritmo/tonalidad para el orden inteligente.
  int analyzedCount = 0;
  int analyzeTotal = 0;

  final _features = TrackFeaturesStore.instance;

  /// BPM/tonalidad ya analizados de [song] (null si todavía no).
  TrackFeatures? featuresOf(Song song) => _features.cached(song.filePath);

  BasicPlayer get _active => _usingA ? _playerA : _playerB;
  BasicPlayer get _standby => _usingA ? _playerB : _playerA;

  Song? get currentSong =>
      _index >= 0 && _index < _queue.length ? _queue[_index] : null;
  Song? get nextSong => _index + 1 < _queue.length ? _queue[_index + 1] : null;

  /// Canciones después de la que está sonando, en orden. Reordenarla con
  /// [reorderUpcoming] cambia directamente cuál es la próxima en cruzar,
  /// porque [nextSong] siempre lee la posición siguiente a [_index].
  List<Song> get upcomingQueue =>
      _index + 1 < _queue.length ? _queue.sublist(_index + 1) : const [];

  /// [newIndex] ya viene ajustado por el llamador (convención de
  /// [ReorderableListView.onReorder]: si es mayor que [oldIndex], restarle
  /// 1 antes de llamar acá), igual que [AppAudioHandler.moveQueueItem].
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

  /// [smartOrder]: antes de arrancar analiza ritmo y tonalidad de todas y
  /// las ordena como un DJ (tempos y tonos que combinan, energía que sube de
  /// a poco, arrancando por la más tranquila).
  Future<void> start(List<Song> queue, {bool smartOrder = false}) async {
    _queue = queue;
    _index = 0;
    if (_queue.isEmpty) return;

    if (smartOrder && _queue.length > 2) {
      status = AutomixStatus.analyzing;
      analyzedCount = 0;
      analyzeTotal = _queue.length;
      notifyListeners();
      for (final song in _queue) {
        await _features.featuresFor(song.filePath,
            durationMs: song.duration?.inMilliseconds);
        analyzedCount++;
        notifyListeners();
        if (status != AutomixStatus.analyzing) return; // se canceló
      }
      final known = [
        for (final song in _queue)
          if (featuresOf(song) != null) song
      ];
      if (known.isNotEmpty) {
        known.sort(
            (a, b) => featuresOf(a)!.energy.compareTo(featuresOf(b)!.energy));
        _queue
          ..remove(known.first)
          ..insert(0, known.first);
      }
      _queue = orderForMixing(_queue, featuresOf);
    }

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
      // BasicPlayer.play() vuelve apenas arranca (en just_audio el Future
      // de play() recién se resuelve al pausar/terminar; eso ya lo maneja
      // BasicPlayer).
      await _active.play();

      status = AutomixStatus.playing;
      _reportState();
      unawaited(_loadPeaksForCurrent());
      unawaited(_applyGainWhenReady(_queue[0], _active));
      _prefetchFeatures();
    } catch (_) {
      // El primer archivo falló al cargar: no tiene sentido quedarse en la
      // pantalla de carga para siempre.
      status = AutomixStatus.finished;
    } finally {
      _listenForCrossfade();
      notifyListeners();
    }
  }

  Future<void> _applyGainWhenReady(Song song, BasicPlayer player) async {
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

  Future<void> _loadIntoPlayer(BasicPlayer player, Song song) {
    return player.setFilePath(song.filePath);
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

      // Un poco antes de los 8s: si hay análisis de ritmo, el cruce espera
      // al próximo pulso para arrancar justo en el golpe.
      if (nextSong != null &&
          remaining <= _crossfadeDuration + const Duration(milliseconds: 700)) {
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

      // Cruce sobre el pulso: arranca en un golpe de la que termina, la que
      // entra desde su primer golpe y a su mismo tempo (±8 %), volviendo de
      // a poco a su velocidad normal después.
      var speed = 1.0;
      final fromFeatures = featuresOf(from);
      final toFeatures = featuresOf(to);
      final total = active.duration;
      if (fromFeatures != null &&
          toFeatures != null &&
          fromFeatures.hasTempo &&
          toFeatures.hasTempo &&
          total != null) {
        speed = speedToMatchTempo(fromFeatures, toFeatures);
        await standby
            .seek(Duration(milliseconds: firstBeatOf(toFeatures).round()));
        final beatAt = fromFeatures.nextBeatAfter(
            (total - _crossfadeDuration).inMilliseconds.toDouble());
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (active.position.inMilliseconds < beatAt - 15 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      await standby.setVolume(0);
      await standby.setSpeed(speed);
      await standby.play();

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
      if (speed != 1.0) unawaited(_glideToNormalSpeed(standby, speed));
      _prefetchFeatures();
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

  /// Vuelve de a poco a la velocidad normal después de un cruce con los
  /// tempos emparejados (en ~6s, imperceptible).
  Future<void> _glideToNormalSpeed(BasicPlayer player, double from) async {
    const steps = 20;
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (player != _active || status == AutomixStatus.idle) return;
      await player.setSpeed(from + (1.0 - from) * i / steps);
    }
  }

  /// Analiza de antemano la que sigue, para que el cruce pueda ir al pulso.
  void _prefetchFeatures() {
    final next = nextSong;
    if (next == null) return;
    unawaited(_features.featuresFor(next.filePath,
        durationMs: next.duration?.inMilliseconds));
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
    await _active.play();
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
