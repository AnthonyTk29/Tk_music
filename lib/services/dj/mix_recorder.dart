import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// "Grabar mezcla" del Modo DJ: graba lo que sale por la salida de audio de
/// la computadora (el estéreo que se escucha: deck A a la izquierda y deck
/// B a la derecha, ya mezclados) a un WAV en Música\TK Music\Mezclas.
///
/// La captura es nativa (windows/runner/loopback_recorder_plugin.cpp,
/// "loopback" de WASAPI), así que graba exactamente lo que suena: si en ese
/// momento suena otra app, también queda en la grabación.
class MixRecorder extends ChangeNotifier {
  MixRecorder({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('tk_music/loopback_recorder');

  final MethodChannel _channel;

  /// Solo en Windows existe la captura de la salida.
  static bool get supported => !kIsWeb && Platform.isWindows;

  bool _recording = false;
  bool _busy = false;
  Duration _elapsed = Duration.zero;
  double _peak = 0;
  String? _path;
  Timer? _poll;

  /// Si la grabación se corta sola (se desconectó la salida, archivo
  /// demasiado grande…), el mensaje para mostrar.
  void Function(String message)? onInterrupted;

  bool get recording => _recording;
  bool get busy => _busy;
  Duration get elapsed => _elapsed;

  /// Nivel de la señal grabada (0–1, más de 1 satura), para el vúmetro.
  double get peak => _peak;

  /// El archivo que se está grabando o el último grabado.
  String? get path => _path;

  /// Empieza a grabar. Devuelve el mensaje de error, o `null` si arrancó.
  /// [deviceId]: la salida de Windows a grabar (la de los decks, por
  /// ejemplo la placa de un controlador); sin él, la predeterminada.
  Future<String?> start({String? deviceId}) async {
    if (_recording || _busy) return null;
    if (!supported) return 'Grabar la mezcla solo funciona en Windows.';
    _busy = true;
    notifyListeners();
    try {
      final info = await _channel.invokeMapMethod<String, Object?>(
          'start', {if (deviceId != null) 'deviceId': deviceId});
      _path = info?['path'] as String?;
      _recording = true;
      _elapsed = Duration.zero;
      _peak = 0;
      _poll = Timer.periodic(
          const Duration(milliseconds: 200), (_) => unawaited(_refresh()));
      return null;
    } on PlatformException catch (e) {
      return e.message ?? 'No se pudo empezar a grabar.';
    } on MissingPluginException {
      return 'Grabar la mezcla no está disponible en esta versión.';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Termina la grabación. Devuelve el mensaje para mostrar.
  Future<String?> stop() async {
    if (!_recording) return null;
    _poll?.cancel();
    _poll = null;
    _busy = true;
    notifyListeners();
    try {
      final info = await _channel.invokeMapMethod<String, Object?>('stop');
      _path = info?['path'] as String? ?? _path;
      final ms = (info?['durationMs'] as num?)?.toInt() ?? 0;
      _elapsed = Duration(milliseconds: ms);
      return 'Mezcla guardada (${formatRecordingTime(_elapsed)}): '
          '${_path ?? ''}';
    } on PlatformException catch (e) {
      return e.message ?? 'No se pudo cerrar la grabación.';
    } finally {
      _recording = false;
      _busy = false;
      _peak = 0;
      notifyListeners();
    }
  }

  Future<String?> toggle({String? deviceId}) =>
      _recording ? stop() : start(deviceId: deviceId);

  Future<void> _refresh() async {
    try {
      final status = await _channel.invokeMapMethod<String, Object?>('status');
      if (status == null || !_recording) return;
      _elapsed =
          Duration(milliseconds: (status['durationMs'] as num?)?.toInt() ?? 0);
      _peak = (status['peak'] as num?)?.toDouble() ?? 0;
      if (status['recording'] != true) {
        final error = status['error'] as String?;
        final saved = await stop();
        onInterrupted?.call(
            error == null ? (saved ?? '') : '$error ${saved ?? ''}'.trim());
        return;
      }
      notifyListeners();
    } catch (_) {}
  }

  @override
  void dispose() {
    _poll?.cancel();
    // Saliendo del Modo DJ grabando: se cierra el archivo igual.
    if (_recording) unawaited(_channel.invokeMethod<void>('stop'));
    super.dispose();
  }
}

/// 1:05:09 / 04:32.
String formatRecordingTime(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}
