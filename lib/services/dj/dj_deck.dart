import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/services/track_features.dart';
import 'package:tk_music/services/track_features_store.dart';
import 'package:tk_music/services/waveform_store.dart';

import 'band_waveform.dart';
import 'dj_math.dart';

// Cadena de audio de los decks. La libmpv de la app trae FFmpeg recortado:
// de sus filtros de audio solo tiene `equalizer`, y tampoco su conversor de
// formatos. Todo lo que sigue está armado con eso y medido con la salida
// real (test/dj_output_test.dart); cambiar el orden rompe cosas:
//  - el ecualizador solo acepta muestras planas: los WAV/FLAC (enteros
//    intercalados) se convierten antes con el conversor propio de mpv;
//  - las tres bandas van en UN solo filtro de FFmpeg (varios seguidos cortan
//    el audio de los archivos estéreo) y antes del paso a mono;
//  - el scaletempo (cambio de tonalidad) va al final.

/// Bandas del ecualizador del deck: graves, medios, agudos. Cada una es un
/// `equalizer` con nombre dentro del filtro "eq", para moverla en caliente
/// con af-command.
const djEqTargets = ['equalizer@lo', 'equalizer@mid', 'equalizer@hi'];
const _djEqBands = ['f=80:t=o:w=2', 'f=1000:t=o:w=1.5', 'f=8000:t=o:w=2'];

const _djPlanar = 'format=doublep';
const _djToMono = 'format=channels=mono,format=channels=stereo';

/// Salida dividida, como en un controlador con salida para mixer externo:
/// el deck A sale en mono solo por la izquierda y el B en mono solo por la
/// derecha, conecte lo que conecte. Después de pasar a mono (copiado a los
/// dos lados), apaga el otro lado con ecualizadores a -60 dB repartidos en
/// todo el rango audible (sin `pan` en esta libmpv, es lo que hay).
String _djSideKill(String deckLabel) {
  final silence = deckLabel == 'A' ? 'FR' : 'FL';
  final kill = [
    for (final f in const [
      20, 40, 80, 160, 315, 630, 1250, 2500, 5000, 10000, 16000 //
    ])
      'equalizer=f=$f:t=o:w=2:g=-60:c=$silence',
  ].join(',');
  return '@side:lavfi=[$kill]';
}

/// Cadena completa de un deck: ecualizador ([eq] en dB), mono por su lado
/// y, si hay cambio de tonalidad, el scaletempo con [tempoScale].
String djDeckChain(String deckLabel, List<double> eq, {double? tempoScale}) {
  final bands = [
    for (var i = 0; i < 3; i++)
      '${djEqTargets[i]}=${_djEqBands[i]}:g=${eq[i].toStringAsFixed(1)}',
  ].join(',');
  final eqFilters = '@eq:lavfi=[$bands]';
  final chain = '$_djPlanar,$eqFilters,$_djToMono,${_djSideKill(deckLabel)}';
  if (tempoScale == null) return chain;
  return '$chain,scaletempo=scale=${tempoScale.toStringAsFixed(5)}';
}

/// Lo mínimo para que algo suene solo por el lado de un deck (la prueba de
/// salida).
String djSideFilter(String deckLabel) =>
    '$_djPlanar,$_djToMono,${_djSideKill(deckLabel)}';

/// Una salida de audio de mpv: [name] es lo que va en `audio-device`
/// ("wasapi/{id}") y [description] lo que ve el usuario ("Altavoces
/// (Mixtrack Pro 3)").
class DjAudioDevice {
  const DjAudioDevice(this.name, this.description);
  final String name;
  final String description;

  /// El id de Windows de la salida (lo que usa la grabación), o `null`
  /// para la predeterminada.
  String? get windowsId =>
      name.startsWith('wasapi/') ? name.substring('wasapi/'.length) : null;
}

/// La lista `audio-device-list` de mpv (JSON) sin "auto" ni duplicados.
List<DjAudioDevice> parseMpvAudioDevices(String json) {
  final list = jsonDecode(json);
  if (list is! List) return const [];
  final out = <DjAudioDevice>[];
  for (final item in list) {
    if (item is! Map) continue;
    final name = item['name'];
    final description = item['description'];
    if (name is! String || name == 'auto') continue;
    out.add(DjAudioDevice(name, description is String ? description : name));
  }
  return out;
}

/// Un loop activo: de [startMs] a [endMs] de la canción.
class DjLoop {
  const DjLoop(this.startMs, this.endMs, this.beats);
  final double startMs;
  final double endMs;

  /// Largo en pulsos (null si la canción no tiene grilla de pulsos).
  final double? beats;
}

/// Una bandeja del modo DJ (desktop): su propio reproductor mpv, con pitch
/// (±8/16/32 %) y keylock, cambio de tonalidad, ecualizador de 3 bandas,
/// cue, hot cues, saltos de pulsos y loops exactos (el A-B loop de mpv).
class DjDeck extends ChangeNotifier {
  DjDeck(this.label) {
    _subs.addAll([
      _player.stream.position.listen(_onPosition),
      _player.stream.duration.listen((d) {
        durationMs = d.inMilliseconds.toDouble();
        notifyListeners();
      }),
      _player.stream.playing.listen((p) {
        if (p == playing) return;
        _stampPosition(_positionEstimate());
        playing = p;
        notifyListeners();
      }),
      _player.stream.completed.listen((done) {
        if (!done) return;
        playing = false;
        notifyListeners();
      }),
    ]);
    unawaited(_configure());
  }

  /// "A" o "B".
  final String label;
  final _player = Player(
    configuration: const PlayerConfiguration(title: 'TK Music DJ'),
  );
  final List<StreamSubscription<Object?>> _subs = [];

  static final _waveforms = WaveformStore();

  /// Las formas de onda se analizan de a una (el análisis nativo atiende un
  /// pedido por vez; cargar los dos decks juntos cancelaría el primero).
  static Future<void> _waveformQueue = Future.value();

  Song? song;
  TrackFeatures? features;
  List<double>? peaks;

  /// Onda detallada por bandas (ver [BandWaveform]); `null` mientras se
  /// calcula o si no se pudo.
  BandWaveform? bands;

  /// Calculando BPM y tonalidad.
  bool analyzing = false;

  /// No se pudo calcular el BPM/tonalidad (se puede reintentar).
  bool analysisFailed = false;
  bool loadingWaveform = false;
  double durationMs = 0;
  bool playing = false;

  /// Pitch como fracción (0.05 = +5 %) dentro de [range].
  double pitch = 0;
  double range = djPitchRanges.first;

  /// Mantiene el tono al cambiar el tempo (si no, suena como un vinilo).
  bool keylock = true;

  /// Semitonos de cambio de tonalidad (sin cambiar el tempo).
  int keyShift = 0;

  /// Corrección temporal de tempo (pitch bend con el plato, y el ajuste
  /// fino del auto sync). No se ve en el pitch.
  double _bend = 0;

  /// Sigue sola el tempo y los pulsos del otro deck (Auto sync).
  bool autoSync = false;

  /// Fader del canal, 0 a 1.
  double volume = 0.8;

  /// GAIN del canal (potenciador), en dB: de -12 a +12. Por encima de 0 la
  /// canción suena más fuerte que el original y puede saturar (esta libmpv
  /// no trae limitador): el vúmetro lo marca.
  double gainDb = 0;
  static const maxGainDb = 12.0;
  double get gainLinear => math.pow(10, gainDb / 20).toDouble();
  double _outputGain = 1;

  /// Lado por el que sale el deck (ver [djSideFilter]).
  String get sideLabel => label == 'A' ? 'IZQ' : 'DER';

  /// Ecualizador en dB: graves, medios, agudos (-26 = "kill").
  final eq = <double>[0, 0, 0];
  static const eqKill = -26.0;

  double? cueMs;
  final hotCues = List<double?>.filled(8, null);
  DjLoop? loop;

  /// El último bucle que estuvo activo (para "reloop").
  DjLoop? lastLoop;

  /// Comienzo marcado con "loop in" (controlador), esperando el final.
  double? loopInMs;

  /// Salida de audio de mpv ("auto" = la predeterminada de Windows, o
  /// "wasapi/{id}" de una placa en particular, como la de un controlador).
  String audioDevice = 'auto';

  double _posMs = 0;
  final _clock = Stopwatch()..start();
  int _stamp = 0;

  bool get loaded => song != null;
  double get tempo => 1 + pitch;
  double get _speedTempo => tempo + _bend;

  /// BPM con el que suena ahora (null sin análisis de ritmo).
  double? get bpm => features?.hasTempo == true ? features!.bpm * tempo : null;

  /// Tonalidad con la que suena (con el cambio de semitonos aplicado; sin
  /// keylock el tempo también la mueve).
  int? get effectiveKey {
    final f = features;
    if (f == null || !f.hasKey) return null;
    var shift = keyShift.toDouble();
    if (!keylock) shift += 12 * math.log(tempo) / math.ln2;
    final semis = shift.round();
    final pc = ((f.pitchClass + semis) % 12 + 12) % 12;
    return f.isMinor ? 12 + pc : pc;
  }

  /// Posición actual en ms de la canción, estimada entre avisos del
  /// reproductor (llegan cada ~100 ms; la forma de onda y el sync necesitan
  /// más precisión).
  double get positionMs => _positionEstimate();

  double _positionEstimate() {
    if (!playing) return _posMs;
    final elapsed = _clock.elapsedMilliseconds - _stamp;
    final estimate = _posMs + elapsed * _speedTempo;
    return durationMs > 0 ? estimate.clamp(0, durationMs) : estimate;
  }

  void _stampPosition(double ms) {
    _posMs = ms;
    _stamp = _clock.elapsedMilliseconds;
  }

  void _onPosition(Duration position) {
    _stampPosition(position.inMilliseconds.toDouble());
  }

  NativePlayer? get _native {
    final platform = _player.platform;
    return platform is NativePlayer ? platform : null;
  }

  Future<void> _configure() async {
    final native = _native;
    if (native == null) return;
    // Saltos exactos (cue, loops, sync) y que el deck no se descargue al
    // terminar la canción.
    await native.setProperty('hr-seek', 'yes');
    await native.setProperty('keep-open', 'yes');
    // Deja subir por encima del 100 % (GAIN y MASTER): hasta ×4 (+12 dB)
    // cabe con holgura en 400 (la escala de mpv es cúbica: 400 = ×64).
    await native.setProperty('volume-max', '400');
    await native.setProperty('audio-pitch-correction', 'yes');
    if (audioDevice != 'auto') {
      await native.setProperty('audio-device', audioDevice);
    }
    await _applyFilters();
  }

  /// Cambia la salida de audio de este deck (ver [audioDevice]).
  Future<void> setAudioDevice(String device) async {
    audioDevice = device;
    notifyListeners();
    await _native?.setProperty('audio-device', device);
  }

  /// Las salidas de audio que ve mpv.
  Future<List<DjAudioDevice>> audioDevices() async {
    final native = _native;
    if (native == null) return const [];
    try {
      return parseMpvAudioDevices(
          await native.getProperty('audio-device-list'));
    } catch (_) {
      return const [];
    }
  }

  // ---------------------------------------------------------------------
  // Carga
  // ---------------------------------------------------------------------

  Future<void> load(Song value) async {
    await _setLoop(null);
    song = value;
    features = TrackFeaturesStore.instance.cached(value.filePath);
    peaks = null;
    bands = null;
    durationMs = value.duration?.inMilliseconds.toDouble() ?? 0;
    cueMs = features?.firstBeatMs ?? 0;
    hotCues.fillRange(0, hotCues.length, null);
    playing = false;
    autoSync = false;
    _bend = 0;
    keyShift = 0;
    analysisFailed = false;
    _stampPosition(cueMs!);
    notifyListeners();

    await _player.open(Media(value.filePath), play: false);
    await _applySpeed();
    if (cueMs! > 0) await seekMs(cueMs!);

    // Primero el BPM/tonalidad (se muestra apenas está) y después la forma
    // de onda por bandas, que decodifica la canción entera (el análisis
    // nativo atiende de a un pedido).
    final analysis =
        features == null ? _analyzeFeatures(value) : Future<void>.value();
    // La onda no espera más de 5 s al BPM: si se demora, arranca igual.
    unawaited(analysis
        .timeout(const Duration(seconds: 5), onTimeout: () {})
        .catchError((Object _) {})
        .whenComplete(() => _loadBands(value)));
    await analysis;
  }

  /// Onda detallada por bandas (graves, medios, agudos) para dibujar como en
  /// los programas de DJ; de ella salen también los picos generales
  /// ([peaks]). Si no se puede, queda la onda simple de antes.
  Future<void> _loadBands(Song value) async {
    if (song != value) return;
    loadingWaveform = true;
    notifyListeners();
    final wave = await BandWaveformStore.instance.load(value.filePath);
    if (song != value) return;
    if (wave == null) {
      loadingWaveform = false;
      await _loadWaveform(value);
      return;
    }
    bands = wave;
    peaks ??= wave.toPeaks(WaveformStore.buckets);
    loadingWaveform = false;
    notifyListeners();
  }

  /// BPM y tonalidad. Con tiempo máximo: si el análisis se traba o falla,
  /// el deck muestra "reintentar" en vez de quedar analizando para siempre.
  Future<void> _analyzeFeatures(Song value) async {
    analyzing = true;
    analysisFailed = false;
    notifyListeners();
    TrackFeatures? found;
    try {
      found = await TrackFeaturesStore.instance
          .featuresFor(value.filePath,
              durationMs: value.duration?.inMilliseconds)
          .timeout(const Duration(seconds: 75));
    } catch (_) {
      found = null;
    }
    if (song != value) return;
    analyzing = false;
    analysisFailed = found == null;
    if (found != null) {
      features = found;
      // El cue automático va al primer pulso (como hace VirtualDJ).
      if ((cueMs ?? 0) == 0 && !playing && _positionEstimate() < 50) {
        cueMs = found.firstBeatMs;
        await seekMs(found.firstBeatMs);
      }
    }
    notifyListeners();
  }

  Future<void> _loadWaveform(Song value) async {
    loadingWaveform = true;
    notifyListeners();
    final wave = await _queueWaveform(value);
    if (song != value) return;
    if (wave != null) peaks = wave;
    loadingWaveform = false;
    notifyListeners();
  }

  /// Vuelve a analizar lo que falló (BPM/tonalidad y forma de onda).
  Future<void> retryAnalysis() async {
    final value = song;
    if (value == null || analyzing) return;
    if (peaks == null && !loadingWaveform) unawaited(_loadBands(value));
    if (features == null) await _analyzeFeatures(value);
  }

  Future<List<double>?> _queueWaveform(Song value) {
    final completer = Completer<List<double>?>();
    _waveformQueue = _waveformQueue.then((_) async {
      try {
        // Con tope: un pedido trabado no deja esperando a la otra bandeja.
        completer.complete(await _waveforms
            .waveformFor(
              mediaStoreId: value.mediaStoreId,
              filePath: value.filePath,
              onProgress: (partial) {
                if (song == value) {
                  peaks = partial;
                  notifyListeners();
                }
              },
            )
            .timeout(const Duration(seconds: 90)));
      } catch (_) {
        completer.complete(null);
      }
    });
    return completer.future;
  }

  // ---------------------------------------------------------------------
  // Transporte
  // ---------------------------------------------------------------------

  Future<void> play() async {
    if (!loaded) return;
    if (durationMs > 0 && _positionEstimate() >= durationMs - 50) {
      await seekMs(cueMs ?? 0);
    }
    await _player.play();
  }

  Future<void> pause() => _player.pause();

  Future<void> togglePlay() => playing ? pause() : play();

  Future<void> seekMs(double ms) async {
    if (!loaded) return;
    final target =
        durationMs > 0 ? ms.clamp(0.0, durationMs) : math.max(0.0, ms);
    _stampPosition(target);
    notifyListeners();
    await _player.seek(Duration(milliseconds: target.round()));
  }

  /// CUE como en un controlador: sonando, vuelve al punto de cue y frena;
  /// frenado, marca el cue donde está (en el pulso más cercano).
  Future<void> cue() async {
    if (!loaded) return;
    if (playing) {
      await pause();
      await seekMs(cueMs ?? 0);
      return;
    }
    cueMs = _quantize(_positionEstimate());
    notifyListeners();
    await seekMs(cueMs!);
  }

  /// Hot cue [index]: si está vacío lo marca acá; si no, salta a él (sigue
  /// sonando si estaba sonando).
  Future<void> hotCue(int index) async {
    if (!loaded) return;
    final existing = hotCues[index];
    if (existing == null) {
      hotCues[index] = _quantize(_positionEstimate());
      notifyListeners();
      return;
    }
    await seekMs(existing);
  }

  void clearHotCue(int index) {
    hotCues[index] = null;
    notifyListeners();
  }

  /// Salta [beats] pulsos hacia adelante (+) o atrás (-). Sin grilla,
  /// medio segundo por pulso.
  Future<void> beatJump(double beats) async {
    final period = features?.hasTempo == true ? features!.beatPeriodMs : 500;
    final l = loop;
    if (l != null) {
      // Con loop activo se mueve el loop entero, como en VirtualDJ.
      final shift = beats * period;
      await _setLoop(DjLoop(l.startMs + shift, l.endMs + shift, l.beats));
    }
    await seekMs(_positionEstimate() + beats * period);
  }

  double _quantize(double ms) {
    final f = features;
    return f != null && f.hasTempo ? nearestBeat(f, ms) : ms;
  }

  // ---------------------------------------------------------------------
  // Loops
  // ---------------------------------------------------------------------

  /// Loop de [beats] pulsos desde el pulso actual. Si ya hay uno de ese
  /// largo, lo apaga.
  Future<void> toggleLoop(double beats) async {
    if (!loaded) return;
    final current = loop;
    if (current != null && current.beats == beats) {
      await exitLoop();
      return;
    }
    final f = features;
    final now = _positionEstimate();
    final period = f != null && f.hasTempo ? f.beatPeriodMs : 500.0;
    final start = current?.startMs ??
        (f != null && f.hasTempo ? beatAtOrBefore(f, now) : now);
    await _setLoop(DjLoop(start, start + beats * period, beats));
  }

  /// Auto loop: busca una parte musical pareja cerca y arma un loop de 4
  /// pulsos; tocándolo de nuevo pasa a 8, a 16 y se apaga.
  Future<void> autoLoop() async {
    final f = features;
    if (!loaded || f == null || !f.hasTempo) {
      await toggleLoop(4);
      return;
    }
    final current = loop;
    final next = switch (current?.beats) {
      null => 4.0,
      4.0 => 8.0,
      8.0 => 16.0,
      _ => null,
    };
    if (next == null) {
      await exitLoop();
      return;
    }
    final start = current?.startMs ??
        suggestAutoLoopStart(
          features: f,
          peaks: peaks,
          durationMs: durationMs,
          positionMs: _positionEstimate(),
          beats: next.toInt(),
        );
    await _setLoop(DjLoop(start, start + next * f.beatPeriodMs, next));
  }

  Future<void> halveLoop() async {
    final l = loop;
    if (l == null) return;
    final beats = l.beats == null ? null : l.beats! / 2;
    if (beats != null && beats < 1 / 8) return;
    await _setLoop(
        DjLoop(l.startMs, l.startMs + (l.endMs - l.startMs) / 2, beats));
  }

  Future<void> doubleLoop() async {
    final l = loop;
    if (l == null) return;
    final beats = l.beats == null ? null : l.beats! * 2;
    if (beats != null && beats > 64) return;
    await _setLoop(
        DjLoop(l.startMs, l.startMs + (l.endMs - l.startMs) * 2, beats));
  }

  Future<void> exitLoop() => _setLoop(null);

  /// "Loop in" de un controlador: marca el comienzo (en el pulso más
  /// cercano) y espera el "loop out".
  void markLoopIn() {
    if (!loaded) return;
    loopInMs = _quantize(_positionEstimate());
    notifyListeners();
  }

  /// "Loop out": cierra el bucle desde el "loop in" hasta acá. Sin "loop
  /// in" marcado, apaga el bucle activo.
  Future<void> markLoopOut() async {
    final start = loopInMs;
    if (!loaded || start == null) {
      if (loop != null) await exitLoop();
      return;
    }
    final end = _quantize(_positionEstimate());
    loopInMs = null;
    if (end - start < 40) {
      notifyListeners();
      return;
    }
    final f = features;
    final beats = f != null && f.hasTempo
        ? ((end - start) / f.beatPeriodMs * 8).round() / 8
        : null;
    await _setLoop(DjLoop(start, end, beats));
    await seekMs(start);
  }

  /// "Reloop / exit": con bucle, lo apaga; sin bucle, vuelve a activar el
  /// último y salta a su comienzo.
  Future<void> reloop() async {
    if (loop != null) {
      await exitLoop();
      return;
    }
    final last = lastLoop;
    if (!loaded || last == null) return;
    await _setLoop(last);
    await seekMs(last.startMs);
  }

  Future<void> _setLoop(DjLoop? value) async {
    loop = value;
    if (value != null) lastLoop = value;
    notifyListeners();
    final native = _native;
    if (native == null) return;
    if (value == null) {
      await native.setProperty('ab-loop-a', 'no');
      await native.setProperty('ab-loop-b', 'no');
      return;
    }
    await native.setProperty(
        'ab-loop-a', (value.startMs / 1000).toStringAsFixed(4));
    await native.setProperty(
        'ab-loop-b', (value.endMs / 1000).toStringAsFixed(4));
    // Si ya pasó el final del loop, vuelve al comienzo (como un "reloop").
    if (_positionEstimate() > value.endMs) await seekMs(value.startMs);
  }

  // ---------------------------------------------------------------------
  // Pitch, tonalidad y sonido
  // ---------------------------------------------------------------------

  Future<void> setPitch(double value) async {
    pitch = value.clamp(-range, range);
    notifyListeners();
    await _applySpeed();
  }

  /// Tempo exacto (lo usa Sync): agranda el rango si no entra.
  Future<void> setTempo(double value) async {
    final needed = pitchRangeFor(value);
    if (needed == null) return;
    if (needed > range) range = needed;
    await setPitch(value - 1);
  }

  Future<void> setRange(double value) async {
    range = value;
    await setPitch(pitch);
  }

  Future<void> setKeylock(bool value) async {
    keylock = value;
    notifyListeners();
    await _applySpeed();
  }

  Future<void> setKeyShift(int semitones) async {
    keyShift = semitones.clamp(-6, 6);
    notifyListeners();
    await _applySpeed();
  }

  /// Corrección fina del tempo sin tocar el pitch (plato y auto sync).
  Future<void> setBend(double value) async {
    final clamped = value.clamp(-0.1, 0.1);
    if ((clamped - _bend).abs() < 0.0004) return;
    _bend = clamped;
    await _applySpeed();
  }

  double get bend => _bend;

  String? _lastAf;

  /// Velocidad de mpv: sin cambio de tonalidad es el tempo (mpv mantiene
  /// el tono solo si hay keylock); con cambio de tonalidad, la velocidad
  /// sube/baja el tono y un scaletempo devuelve el tempo que corresponde.
  double get _mpvSpeed {
    if (keyShift == 0) return _speedTempo;
    final factor = math.pow(2, keyShift / 12).toDouble();
    return keylock ? factor : factor * _speedTempo;
  }

  /// Ver [djDeckChain].
  String _desiredAf() => djDeckChain(label, eq,
      tempoScale: keyShift == 0 ? null : _speedTempo / _mpvSpeed);

  Future<void> _applySpeed() async {
    final native = _native;
    if (native == null) return;
    // Sin cambio de tonalidad, mover el pitch solo cambia la velocidad: no
    // corta el sonido.
    await native.setProperty(
        'audio-pitch-correction', keyShift == 0 && keylock ? 'yes' : 'no');
    await _setAf(_desiredAf());
    await native.setProperty('speed', _mpvSpeed.toStringAsFixed(5));
  }

  Future<void> _setAf(String value) async {
    if (value == _lastAf) return;
    _lastAf = value;
    await _native?.setProperty('af', value);
  }

  /// Ecualizador de la banda [band] (0 graves, 1 medios, 2 agudos), en
  /// caliente: se le cambia la ganancia al filtro sin rearmar la cadena
  /// (rearmarla corta el sonido un instante).
  Future<void> setEq(int band, double db) async {
    eq[band] = db.clamp(eqKill, 6.0);
    notifyListeners();
    final native = _native;
    if (native == null) return;
    try {
      await native.command([
        'af-command',
        'eq',
        'g',
        eq[band].toStringAsFixed(1),
        djEqTargets[band],
      ]);
      // La cadena que ya tiene mpv equivale a la nueva: no hace falta
      // rearmarla la próxima vez que se mueva el pitch.
      if (_lastAf != null) _lastAf = _desiredAf();
    } catch (_) {
      _lastAf = null;
      await _applySpeed();
    }
  }

  /// Volumen final = fader del canal × crossfader × master.
  Future<void> setVolume(double value) async {
    volume = value.clamp(0.0, 1.0);
    notifyListeners();
    await _applyVolume();
  }

  Future<void> setOutputGain(double gain) async {
    if ((gain - _outputGain).abs() < 0.002) return;
    _outputGain = gain;
    await _applyVolume();
  }

  Future<void> setGain(double db) async {
    gainDb = db.clamp(-maxGainDb, maxGainDb);
    notifyListeners();
    await _applyVolume();
  }

  /// Ganancia final (lineal) que sale del deck.
  double get outputLevel => volume * _outputGain * gainLinear;

  /// El volumen de mpv es cúbico (50 % suena a 1/8, no a la mitad): se
  /// convierte para que fader, crossfader, GAIN y MASTER den los dB reales.
  Future<void> _applyVolume() =>
      _player.setVolume(mpvVolumeFor(outputLevel.clamp(0.0, 4.0).toDouble()));

  Future<void> _applyFilters() async {
    _lastAf = null;
    await _applySpeed();
    await _applyVolume();
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    unawaited(_player.dispose());
    super.dispose();
  }
}
