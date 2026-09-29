import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:media_kit/media_kit.dart' as mk;

import 'package:tk_music/core/platform.dart';

/// Reproductor mínimo para los motores que manejan su propio audio aparte
/// del reproductor principal ("Sincronizar con otro dispositivo" y el
/// Mezclador automático): just_audio en Android/iOS, media_kit en desktop —
/// mismas operaciones (cargar archivo o URL/reproducir/pausar/parar/buscar/
/// velocidad/volumen) sin que esos motores tengan que saber cuál de los dos
/// hay abajo.
class BasicPlayer {
  BasicPlayer() : _isDesktop = isDesktopPlatform {
    if (_isDesktop) {
      final player = mk.Player();
      _mkPlayer = player;
      // mpv avisa la posición de a saltos (~cada 50–100 ms): se anota cuándo
      // llegó cada aviso para calcular la posición exacta entre uno y otro
      // (la sincronización entre dispositivos necesita precisión de ms).
      _mkSubs.addAll([
        player.stream.position.listen((p) => _stampDesktop(p)),
        player.stream.playing
            .listen((_) => _stampDesktop(player.state.position)),
        player.stream.rate.listen((_) => _stampDesktop(position)),
      ]);
    } else {
      _jaPlayer = ja.AudioPlayer();
    }
  }

  final bool _isDesktop;
  ja.AudioPlayer? _jaPlayer;
  mk.Player? _mkPlayer;
  final List<StreamSubscription<Object?>> _mkSubs = [];
  final _clock = Stopwatch()..start();
  Duration _mkPosition = Duration.zero;
  int _mkStampUs = 0;

  void _stampDesktop(Duration position) {
    _mkPosition = position;
    _mkStampUs = _clock.elapsedMicroseconds;
  }

  Future<void> setFilePath(String path) async {
    if (_isDesktop) {
      await _mkPlayer!.open(mk.Media(path), play: false);
    } else {
      await _jaPlayer!.setAudioSource(ja.AudioSource.uri(Uri.file(path)));
    }
  }

  /// Carga un id de la cola del reproductor principal: una ruta de archivo o
  /// un URI `content://` (pendrive en Android).
  Future<void> setSource(String id) =>
      id.startsWith('content://') ? setUrl(Uri.parse(id)) : setFilePath(id);

  /// Carga una URL (p. ej. el servidor local de streaming mientras la
  /// canción todavía está llegando por Bluetooth).
  Future<void> setUrl(Uri url) async {
    if (_isDesktop) {
      await _mkPlayer!.open(mk.Media(url.toString()), play: false);
    } else {
      await _jaPlayer!.setAudioSource(ja.AudioSource.uri(url));
    }
  }

  /// Vuelve apenas arranca. Ojo: en just_audio el Future de `play()` recién
  /// se completa cuando la reproducción se pausa o termina — esperarlo
  /// dejaba trabado a quien lo llamaba durante toda la canción.
  Future<void> play() async {
    if (_isDesktop) return _mkPlayer!.play();
    unawaited(_jaPlayer!.play().catchError((Object e) {
      debugPrint('BasicPlayer.play falló: $e');
    }));
  }

  Future<void> pause() => _isDesktop ? _mkPlayer!.pause() : _jaPlayer!.pause();

  Future<void> stop() => _isDesktop ? _mkPlayer!.stop() : _jaPlayer!.stop();

  Future<void> seek(Duration position) {
    if (!_isDesktop) return _jaPlayer!.seek(position);
    _stampDesktop(position);
    return _mkPlayer!.seek(position);
  }

  Future<void> setSpeed(double speed) =>
      _isDesktop ? _mkPlayer!.setRate(speed) : _jaPlayer!.setSpeed(speed);

  /// 1.0 = volumen normal; hasta ~1.3 amplifica (el Automix lo usa para
  /// emparejar temas grabados más bajos).
  Future<void> setVolume(double volume) => _isDesktop
      // media_kit usa la escala de mpv (0-100, y hasta 130 por defecto).
      ? _mkPlayer!.setVolume((volume * 100).clamp(0, 130).toDouble())
      : _jaPlayer!.setVolume(volume);

  bool get playing =>
      _isDesktop ? _mkPlayer!.state.playing : _jaPlayer!.playing;

  /// Esperando datos (p. ej. la parte de la canción que todavía no llegó).
  bool get buffering {
    if (_isDesktop) return _mkPlayer!.state.buffering;
    final state = _jaPlayer!.processingState;
    return state == ja.ProcessingState.buffering ||
        state == ja.ProcessingState.loading;
  }

  /// Posición actual. just_audio ya la calcula entre avisos; en desktop se
  /// calcula acá desde el último aviso de mpv, el tiempo pasado y la
  /// velocidad.
  Duration get position {
    if (!_isDesktop) return _jaPlayer!.position;
    final state = _mkPlayer!.state;
    if (!state.playing || state.buffering) return _mkPosition;
    final elapsedUs = _clock.elapsedMicroseconds - _mkStampUs;
    var estimate =
        _mkPosition + Duration(microseconds: (elapsedUs * state.rate).round());
    if (state.duration > Duration.zero && estimate > state.duration) {
      estimate = state.duration;
    }
    return estimate;
  }

  Stream<Duration> get positionStream =>
      _isDesktop ? _mkPlayer!.stream.position : _jaPlayer!.positionStream;

  Duration? get duration {
    if (!_isDesktop) return _jaPlayer!.duration;
    final duration = _mkPlayer!.state.duration;
    return duration == Duration.zero ? null : duration;
  }

  double get speed => _isDesktop ? _mkPlayer!.state.rate : _jaPlayer!.speed;

  /// Emite cada vez que la canción cargada termina de sonar.
  Stream<void> get completed => _isDesktop
      ? _mkPlayer!.stream.completed.where((done) => done)
      : _jaPlayer!.processingStateStream
          .where((state) => state == ja.ProcessingState.completed);

  Future<void> dispose() async {
    for (final sub in _mkSubs) {
      await sub.cancel();
    }
    return _isDesktop ? _mkPlayer!.dispose() : _jaPlayer!.dispose();
  }
}
