import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Error al abrir un controlador (por ejemplo, lo tiene tomado VirtualDJ).
class MidiException implements Exception {
  const MidiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Acceso a los controladores MIDI (windows/runner/midi_plugin.cpp).
class MidiBridge {
  MidiBridge({MethodChannel? channel, EventChannel? events})
      : _channel = channel ?? const MethodChannel('tk_music/midi'),
        _events = events ?? const EventChannel('tk_music/midi/events');

  final MethodChannel _channel;
  final EventChannel _events;

  static bool get supported => !kIsWeb && Platform.isWindows;

  /// Los nombres de las entradas y salidas MIDI conectadas.
  Future<({List<String> inputs, List<String> outputs})> devices() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('devices');
      List<String> names(Object? list) =>
          [for (final item in (list as List?) ?? const []) '$item'];
      return (inputs: names(map?['inputs']), outputs: names(map?['outputs']));
    } on MissingPluginException {
      return (inputs: const <String>[], outputs: const <String>[]);
    }
  }

  /// Abre [input] (y [output] para las luces). Devuelve si hay luces.
  Future<bool> open(String input, String? output) async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>(
          'open', {'input': input, if (output != null) 'output': output});
      return map?['lights'] == true;
    } on PlatformException catch (e) {
      throw MidiException(e.message ?? 'No se pudo abrir el controlador.');
    }
  }

  /// Manda mensajes de 3 bytes seguidos.
  Future<void> send(List<int> bytes) async {
    try {
      await _channel.invokeMethod<void>('send', {'bytes': bytes});
    } catch (_) {}
  }

  Future<void> close() async {
    try {
      await _channel.invokeMethod<void>('close');
    } catch (_) {}
  }

  /// Lo que manda el controlador, de a tandas [status, d1, d2, status…].
  Stream<List<int>> get messages => _events
      .receiveBroadcastStream()
      .map((batch) => [for (final b in batch as List) b as int]);
}
