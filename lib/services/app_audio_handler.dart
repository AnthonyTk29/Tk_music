import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import 'equalizer_controller.dart';
import 'queue_capable_handler.dart';

/// Lo que las pantallas necesitan del reproductor principal más allá de lo
/// que ya da `AudioHandler`: `MyAudioHandler` (Android) y
/// `DesktopAudioHandler` (desktop) implementan esto igual, así el
/// Ecualizador, el temporizador de apagado y el Mezclador automático
/// funcionan en las dos plataformas sin castear a una clase concreta.
abstract class AppAudioHandler implements QueueCapableHandler {
  EqualizerController get equalizer;

  /// Hora en la que se pausará por el temporizador de apagado, o `null` si
  /// no hay uno activo.
  ValueListenable<DateTime?> get sleepTimerEndsAt;
  void setSleepTimer(Duration duration);
  void cancelSleepTimer();

  /// El Mezclador automático toma prestados los controles del sistema
  /// (notificación en Android, teclas multimedia/panel de Windows) mientras
  /// suena con sus propios reproductores.
  void takeExternalControl({
    required Future<void> Function() onPlay,
    required Future<void> Function() onPause,
    required Future<void> Function() onStop,
    Future<void> Function()? onSkipNext,
  });

  void releaseExternalControl();

  /// Una canción de la cola cambió sus datos (editor de tags): se actualiza
  /// en la cola y, si es la que suena, en "Reproduciendo" y los controles
  /// del sistema. Se identifica por [MediaItem.id] (la ruta).
  void refreshMediaItem(MediaItem item);

  void reportExternalState({
    required String title,
    String? artist,
    required String filePath,
    int? mediaStoreId,
    required bool playing,
    required Duration position,
    Duration? duration,
  });
}
