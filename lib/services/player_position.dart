import 'dart:async';

import 'package:audio_service/audio_service.dart';

import 'package:tk_music/core/di/service_locator.dart';

/// Posición de la reproducción principal, actualizada seguido mientras
/// suena — reemplaza a `AudioService.position`, que depende de
/// `AudioService.init()` y por eso en desktop (donde el reproductor es
/// DesktopAudioHandler y no pasa por ahí) tiraba error apenas alguien lo
/// escuchaba. Esto lee el mismo `playbackState` directo del AudioHandler
/// registrado, así funciona igual en las dos plataformas.
class PlayerPosition {
  PlayerPosition._();

  static Stream<Duration>? _stream;

  /// Stream compartido (broadcast): emite al cambiar el estado y cada
  /// [_tick] mientras suena. Vacío si no hay reproductor disponible.
  static Stream<Duration> get stream => _stream ??= _create();

  static const _tick = Duration(milliseconds: 200);

  static Stream<Duration> _create() {
    if (!isAudioAvailable) return const Stream.empty();
    final handler = sl<AudioHandler>();
    late StreamController<Duration> controller;
    StreamSubscription<PlaybackState>? stateSub;
    Timer? timer;
    Duration? last;

    void emit() {
      final position = handler.playbackState.value.position;
      if (position == last) return;
      last = position;
      controller.add(position);
    }

    controller = StreamController<Duration>.broadcast(
      onListen: () {
        stateSub = handler.playbackState.listen((_) => emit());
        timer = Timer.periodic(_tick, (_) {
          if (handler.playbackState.value.playing) emit();
        });
        last = null;
        emit();
      },
      onCancel: () {
        stateSub?.cancel();
        timer?.cancel();
      },
    );
    return controller.stream;
  }
}
