import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import 'waveform_store.dart';

/// Carga la forma de onda de la canción actual una sola vez, en un único
/// lugar para toda la app. Antes cada pantalla ("Reproduciendo",
/// Ecualizador) tenía su propio State con su propio análisis: navegar entre
/// pantallas, o que Android pusiera el widget en segundo plano, tiraba el
/// progreso a la basura, y la pantalla nueva arrancaba de cero — quedando
/// la onda en una línea plana a mitad de camino hasta que (si acaso)
/// terminaba de cargar de nuevo. Al vivir acá, arrancado una sola vez desde
/// main.dart y no desde ninguna pantalla, el análisis sigue en curso sin
/// importar qué se esté mostrando o si la app está en primer o segundo
/// plano, y solo se reinicia cuando cambia la canción de verdad — como el
/// pre-buffer de YouTube, que no se reinicia porque cambiaste de pantalla.
class WaveformLoader extends ChangeNotifier {
  WaveformLoader._();
  static final WaveformLoader instance = WaveformLoader._();

  final _store = WaveformStore();
  bool _started = false;

  int? _songId;
  List<double>? _peaks;

  int? get songId => _songId;
  List<double>? get peaks => _peaks;

  /// Se llama una sola vez desde main.dart apenas hay un AudioHandler
  /// disponible. Llamadas siguientes no hacen nada (por diseño: no hay
  /// ninguna pantalla "dueña" de este componente).
  void start(AudioHandler handler) {
    if (_started) return;
    _started = true;
    // Sin cancelar nunca a propósito: es un singleton de por vida de la
    // app, igual que AutomixEngine.instance.
    handler.mediaItem.listen((item) {
      final id = item?.extras?['songId'] as int?;
      if (item == null || id == null) {
        if (_songId == null && _peaks == null) return;
        _songId = null;
        _peaks = null;
        notifyListeners();
        return;
      }
      if (id == _songId) return;
      _songId = id;
      _peaks = null;
      notifyListeners();
      unawaited(_load(item, id));
    });
  }

  Future<void> _load(MediaItem item, int songId) async {
    // Punto de partida del análisis: si la canción ya está a la mitad
    // cuando arranca esto, decodifica desde ahí hacia adelante primero (lo
    // próximo que se va a ver), no desde el principio.
    var position = Duration.zero;
    try {
      position = await AudioService.position.first
          .timeout(const Duration(milliseconds: 300));
    } catch (_) {}
    final total = item.duration ?? Duration.zero;
    final fraction = total.inMilliseconds == 0
        ? 0.0
        : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

    final peaks = await _store.waveformFor(
      mediaStoreId: songId,
      filePath: item.id,
      positionFraction: fraction,
      onProgress: (partial) {
        if (_songId != songId) return;
        _peaks = partial;
        notifyListeners();
      },
    );
    if (_songId != songId) return;
    if (peaks != null) _peaks = peaks;
    notifyListeners();
  }
}
