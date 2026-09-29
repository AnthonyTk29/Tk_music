import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:tk_music/core/platform.dart';

import 'basic_player.dart';
import 'loudness_store.dart';
import 'playback_settings.dart';
import 'track_features.dart';
import 'track_features_store.dart';

/// Lo que el coordinador necesita del reproductor principal. Lo implementan
/// MyAudioHandler (just_audio) y DesktopAudioHandler (media_kit).
abstract class MainPlayerAdapter {
  Duration get position;
  Duration? get duration;
  bool get playing;
  Stream<Duration> get positionStream;
  int? get currentIndex;

  /// Índice que va a sonar después del actual (respetando aleatorio y
  /// repetir), o null si no hay.
  int? get nextIndex;
  bool get repeatOne;

  /// Id del elemento [index] de la cola: ruta de archivo o `content://`.
  String? idAt(int index);

  /// Id de la canción en la biblioteca (para el volumen medido), si tiene.
  int? songIdAt(int index);

  /// 1.0 = normal; hasta ~1.3 amplifica.
  Future<void> setVolume(double volume);
  Future<void> seekTo(int index, Duration position);
  Future<void> play();

  /// Algo más tiene el control (p. ej. el Mezclador automático).
  bool get externallyControlled;
}

/// Volumen parejo entre canciones y crossfade del reproductor principal,
/// igual para Android y desktop (ver [PlaybackSettings]).
///
/// Crossfade: cuando falta poco para terminar, un segundo reproductor
/// arranca la canción siguiente y se cruzan los volúmenes (curva de igual
/// potencia). Con el análisis de ritmo disponible, el cruce arranca sobre
/// un pulso de la que termina, la que entra empieza en su primer pulso y se
/// le ajusta la velocidad (±8 % como mucho) para que los tempos coincidan,
/// volviendo de a poco a la normal. Al terminar, el reproductor principal
/// retoma la canción nueva en el mismo punto y el segundo se apaga.
class CrossfadeCoordinator {
  CrossfadeCoordinator(this._main);

  final MainPlayerAdapter _main;
  final _settings = PlaybackSettings.instance;
  final _loudness = LoudnessStore();
  BasicPlayer? _secondary;
  StreamSubscription<Duration>? _positionSub;

  double _gain = 1.0;
  bool _ducked = false;
  bool _fading = false;
  int? _gainIndex;

  // Nivel RMS de referencia: la música actual suele andar entre -9 y -12,
  // así casi no baja; lo grabado más bajo sube (hasta ×1.3).
  static const _targetDb = -12.0;
  static const _maxBeatSpeedChange = 0.08;

  void attach() {
    _positionSub = _main.positionStream.listen(_onPosition);
    _settings.addListener(_onSettingsChanged);
  }

  Future<void> dispose() async {
    _settings.removeListener(_onSettingsChanged);
    await _positionSub?.cancel();
    await _secondary?.dispose();
  }

  /// El reproductor pasó a [index] (canción nueva): se aplica su volumen y
  /// se va analizando el ritmo de esta y la siguiente para el cruce.
  Future<void> onTrackChanged(int? index) async {
    if (_fading || index == null) return;
    await _updateGain(index);
    _prefetchFeatures(index);
    final next = _main.nextIndex;
    if (next != null) _prefetchFeatures(next);
  }

  /// Bajar el volumen mientras otra app habla (notificaciones, llamadas).
  Future<void> setDucked(bool ducked) async {
    _ducked = ducked;
    if (!_fading) await _applyVolume();
  }

  void _onSettingsChanged() {
    final index = _main.currentIndex;
    if (index != null && !_fading) unawaited(_updateGain(index));
  }

  Future<void> _updateGain(int index) async {
    _gainIndex = index;
    final gain = await _gainFor(index);
    if (_gainIndex != index || _fading) return;
    _gain = gain;
    await _applyVolume();
  }

  Future<double> _gainFor(int index) async {
    if (!_settings.normalizeVolume) return 1.0;
    final songId = _main.songIdAt(index);
    final path = _main.idAt(index);
    if (songId == null || path == null || !_isLocalFile(path)) {
      return 1.0;
    }
    if (!hasNativeAudioAnalysis) return 1.0;
    final db = await _loudness.dbForFile(songId, path);
    // Sin medición real (formato que no se pudo decodificar): volumen normal,
    // en vez de tratarla como una canción muy baja.
    if (db == LoudnessStore.neutralDb) return 1.0;
    return math.pow(10, (_targetDb - db) / 20).toDouble().clamp(0.3, 1.3);
  }

  Future<void> _applyVolume() => _main.setVolume(_gain * (_ducked ? 0.3 : 1.0));

  /// Solo se analizan archivos del dispositivo: ni los del pendrive
  /// (`content://`) ni los que suenan por internet.
  static bool _isLocalFile(String path) =>
      !path.startsWith('content://') &&
      !path.startsWith('http://') &&
      !path.startsWith('https://');

  void _prefetchFeatures(int index) {
    if (!_settings.beatMatching || _settings.crossfadeSeconds == 0) return;
    final path = _main.idAt(index);
    if (path == null || !_isLocalFile(path)) return;
    unawaited(TrackFeaturesStore.instance.featuresFor(path));
  }

  void _onPosition(Duration position) {
    final seconds = _settings.crossfadeSeconds;
    if (seconds == 0 ||
        _fading ||
        !_main.playing ||
        _main.externallyControlled ||
        _main.repeatOne) {
      return;
    }
    final duration = _main.duration;
    final next = _main.nextIndex;
    if (duration == null || next == null || next == _main.currentIndex) return;
    // Canciones muy cortas: sin cruce, sonarían solapadas casi enteras.
    if (duration.inMilliseconds < seconds * 3000) return;
    final remaining = duration - position;
    if (remaining <=
            Duration(seconds: seconds) + const Duration(milliseconds: 600) &&
        remaining > const Duration(milliseconds: 1500)) {
      unawaited(_crossfade(next));
    }
  }

  Future<void> _crossfade(int toIndex) async {
    final fromIndex = _main.currentIndex;
    final fromId = fromIndex == null ? null : _main.idAt(fromIndex);
    final toId = _main.idAt(toIndex);
    final duration = _main.duration;
    if (fromIndex == null ||
        fromId == null ||
        toId == null ||
        duration == null) {
      return;
    }
    _fading = true;
    final secondary = _secondary ??= BasicPlayer();
    var handedOff = false;
    try {
      final fromGain = _gain;
      final toGain = await _gainFor(toIndex);
      await secondary.setSource(toId);

      // Cruce sobre el pulso (si ya están analizadas las dos).
      var startOffset = Duration.zero;
      var speed = 1.0;
      final from = _settings.beatMatching
          ? TrackFeaturesStore.instance.cached(fromId)
          : null;
      final to = _settings.beatMatching
          ? TrackFeaturesStore.instance.cached(toId)
          : null;
      if (from != null && to != null && from.hasTempo && to.hasTempo) {
        speed = _speedToMatch(from, to);
        startOffset = Duration(milliseconds: _firstBeatMs(to).round());
        final beatAt = from.nextBeatAfter(
          (duration.inMilliseconds - _settings.crossfadeSeconds * 1000)
              .toDouble(),
        );
        await _waitUntil(Duration(milliseconds: beatAt.round()), fromIndex);
      }
      if (_main.currentIndex != fromIndex) return;

      await secondary.seek(startOffset);
      await secondary.setSpeed(speed);
      await secondary.setVolume(0);
      await secondary.play();

      final remainingMs = (duration - _main.position).inMilliseconds - 250;
      final fadeMs = math.min(_settings.crossfadeSeconds * 1000, remainingMs);
      if (fadeMs <= 300) return;
      const steps = 40;
      final stepDelay = Duration(milliseconds: fadeMs ~/ steps);
      for (var i = 1; i <= steps; i++) {
        // El usuario cambió de canción a mano durante el cruce: se corta.
        if (_main.currentIndex != fromIndex && i < steps - 2) return;
        final t = i / steps;
        final duck = _ducked ? 0.3 : 1.0;
        await _main.setVolume(fromGain * math.cos(t * math.pi / 2) * duck);
        await secondary.setVolume(toGain * math.sin(t * math.pi / 2) * duck);
        if (speed != 1.0 && t > 0.5) {
          await secondary.setSpeed(speed + (1.0 - speed) * ((t - 0.5) * 2));
        }
        await Future<void>.delayed(stepDelay);
      }

      // Traspaso: el principal retoma la canción nueva donde va el segundo.
      await secondary.setSpeed(1.0);
      await _main.setVolume(0);
      await _main.seekTo(
          toIndex, secondary.position + const Duration(milliseconds: 80));
      await _main.play();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final drift = _main.position - secondary.position;
      if (drift.inMilliseconds.abs() > 40) {
        await _main.seekTo(
            toIndex, secondary.position + const Duration(milliseconds: 60));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      _gain = toGain;
      _gainIndex = toIndex;
      await _applyVolume();
      await secondary.setVolume(0);
      handedOff = true;
    } catch (e) {
      debugPrint('Crossfade falló: $e');
    } finally {
      await secondary.pause();
      _fading = false;
      if (!handedOff) {
        // Se cortó a mitad: se deja el principal a su volumen normal.
        final index = _main.currentIndex;
        if (index != null) await _updateGain(index);
      }
      final now = _main.currentIndex;
      if (now != null) {
        final next = _main.nextIndex;
        if (next != null) _prefetchFeatures(next);
      }
    }
  }

  /// Espera a que el principal llegue a [target] (sin pasarse del final).
  Future<void> _waitUntil(Duration target, int index) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (_main.currentIndex == index &&
        _main.position < target - const Duration(milliseconds: 15) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

/// Velocidad para que [to] suene al tempo de [from] (considerando mitad y
/// doble), o 1.0 si hace falta cambiar más de lo que pasa desapercibido.
double _speedToMatch(TrackFeatures from, TrackFeatures to) {
  var best = 1.0;
  var bestChange = double.infinity;
  for (final ratio in [1.0, 2.0, 0.5]) {
    final speed = from.bpm / (to.bpm * ratio);
    final change = (speed - 1).abs();
    if (change < bestChange) {
      bestChange = change;
      best = speed;
    }
  }
  return bestChange <= CrossfadeCoordinator._maxBeatSpeedChange ? best : 1.0;
}

/// Primer pulso de [features] desde el comienzo de la canción.
double _firstBeatMs(TrackFeatures features) {
  final period = features.beatPeriodMs;
  if (period <= 0) return 0;
  return features.firstBeatMs % period;
}

/// Para el Mezclador automático (mismos criterios).
double speedToMatchTempo(TrackFeatures from, TrackFeatures to) =>
    _speedToMatch(from, to);
double firstBeatOf(TrackFeatures features) => _firstBeatMs(features);
