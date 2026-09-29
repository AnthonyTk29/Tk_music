import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Controles multimedia del sistema en Windows (panel de volumen, pantalla
/// de bloqueo y teclas multimedia del teclado) — ver
/// windows/runner/media_controls_plugin.cpp. Es lo que en Android hace la
/// notificación de audio_service.
class WindowsMediaControls {
  static const _channel = MethodChannel('tk_music/media_controls');
  static const _events = EventChannel('tk_music/media_controls/events');

  StreamSubscription<dynamic>? _buttonsSub;

  /// [onButton] recibe play/pause/next/previous/stop.
  void listen(void Function(String button) onButton) {
    _buttonsSub ??= _events.receiveBroadcastStream().listen((raw) {
      final button = (raw as Map)['button'] as String?;
      if (button != null) onButton(button);
    }, onError: (Object e) => debugPrint('Controles del sistema: $e'));
  }

  Future<void> update({
    required String title,
    String? artist,
    String? album,
    required bool playing,
    required Duration position,
    Duration? duration,
    bool canNext = true,
    bool canPrevious = true,
  }) async {
    try {
      await _channel.invokeMethod('update', {
        'title': title,
        'artist': artist ?? '',
        'album': album ?? '',
        'playing': playing,
        'positionMs': position.inMilliseconds,
        'durationMs': duration?.inMilliseconds ?? 0,
        'canNext': canNext,
        'canPrevious': canPrevious,
      });
    } catch (e) {
      debugPrint('No se pudieron actualizar los controles del sistema: $e');
    }
  }

  Future<void> clear() async {
    try {
      await _channel.invokeMethod('clear');
    } catch (e) {
      debugPrint('No se pudieron limpiar los controles del sistema: $e');
    }
  }

  Future<void> dispose() async {
    await _buttonsSub?.cancel();
    _buttonsSub = null;
  }
}
