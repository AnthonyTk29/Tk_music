import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:tk_music/services/app_audio_handler.dart';

import 'dj_deck.dart';
import 'dj_math.dart';

/// El "controlador DJ" de desktop: dos decks, crossfader, master, Sync
/// (tempo y pulsos), Auto sync (mantiene los pulsos alineados sin parar),
/// sincronizar tonalidad y la mezcla automática de un deck al otro en N
/// pulsos.
class DjMixer extends ChangeNotifier {
  DjMixer({AppAudioHandler? mainPlayer}) : _main = mainPlayer {
    for (final deck in decks) {
      deck.addListener(_onDeckChanged);
    }
    _applyGains();
    _syncTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _keepInSync();
    });
    _main?.takeExternalControl(
      onPlay: () async => (_lastPlaying ?? a).play(),
      onPause: () async {
        for (final deck in decks) {
          if (deck.playing) _lastPlaying = deck;
          await deck.pause();
        }
      },
      onStop: () async {
        for (final deck in decks) {
          await deck.pause();
        }
      },
    );
  }

  final AppAudioHandler? _main;
  final a = DjDeck('A');
  final b = DjDeck('B');
  List<DjDeck> get decks => [a, b];
  DjDeck other(DjDeck deck) => identical(deck, a) ? b : a;

  /// -1 = solo A, 1 = solo B.
  double crossfader = 0;

  /// Volumen master (lineal): 1 = original; hasta 2 (+6 dB) para potenciar.
  double master = 1.0;
  static const maxMaster = 2.0;

  late final Timer _syncTimer;
  DjDeck? _lastPlaying;
  Timer? _mixTimer;
  DjDeck? _mixingTo;

  /// Mezcla automática en curso hacia este deck.
  DjDeck? get mixingTo => _mixingTo;

  void _onDeckChanged() {
    final playing = decks.where((d) => d.playing).toList();
    if (playing.length == 1) _lastPlaying = playing.first;
    _reportToSystem();
    notifyListeners();
  }

  /// El deck que marca el ritmo: el que más suena según el crossfader (entre
  /// los que están sonando).
  DjDeck? get masterDeck {
    final playing = decks.where((d) => d.playing && d.bpm != null).toList();
    if (playing.isEmpty) return null;
    if (playing.length == 1) return playing.first;
    return crossfader <= 0 ? a : b;
  }

  Future<void> setCrossfader(double value) async {
    crossfader = value.clamp(-1.0, 1.0);
    notifyListeners();
    await _applyGains();
  }

  Future<void> setMaster(double value) async {
    master = value.clamp(0.0, maxMaster);
    notifyListeners();
    await _applyGains();
  }

  Future<void> _applyGains() async {
    final gains = crossfaderGains(crossfader);
    await a.setOutputGain(gains.a * master);
    await b.setOutputGain(gains.b * master);
  }

  // ---------------------------------------------------------------------
  // Sync
  // ---------------------------------------------------------------------

  /// SYNC: lleva [deck] al tempo del otro y, si los dos suenan, alinea los
  /// pulsos. Devuelve un mensaje si no se pudo.
  Future<String?> sync(DjDeck deck) async {
    final master = other(deck);
    final f = deck.features;
    final mf = master.features;
    if (f == null || !f.hasTempo || mf == null || master.bpm == null) {
      return 'Hace falta el BPM de las dos canciones (se está analizando).';
    }
    final tempo = tempoForSync(f.bpm, master.bpm!);
    if (pitchRangeFor(tempo) == null) {
      return 'Los tempos están demasiado lejos (más de ±32 %).';
    }
    await deck.setBend(0);
    await deck.setTempo(tempo);
    await _alignPhase(deck, master);
    return null;
  }

  Future<void> _alignPhase(DjDeck deck, DjDeck master) async {
    final f = deck.features;
    final mf = master.features;
    if (f == null || mf == null || !f.hasTempo || !mf.hasTempo) return;
    if (!master.playing) return;
    await deck.seekMs(alignedPosition(
      follower: f,
      followerMs: deck.positionMs,
      master: mf,
      masterMs: master.positionMs,
    ));
  }

  /// Auto sync: [deck] sigue solo al otro (tempo y pulsos). Solo uno de los
  /// dos puede seguir al otro.
  Future<String?> setAutoSync(DjDeck deck, bool value) async {
    if (value) {
      final problem = await sync(deck);
      if (problem != null) return problem;
      other(deck).autoSync = false;
    } else {
      await deck.setBend(0);
    }
    deck.autoSync = value;
    notifyListeners();
    return null;
  }

  /// Cada 50 ms: el deck con Auto sync mantiene el tempo del otro y corrige
  /// el desfase de pulsos de a poco (apurándose o frenándose un pelo), o
  /// saltando si se fue lejos.
  Future<void> _keepInSync() async {
    for (final deck in decks) {
      if (!deck.autoSync || !deck.playing) continue;
      final master = other(deck);
      final f = deck.features;
      final mf = master.features;
      final masterBpm = master.bpm;
      if (!master.playing || f == null || mf == null || masterBpm == null) {
        await deck.setBend(0);
        continue;
      }
      final tempo = tempoForSync(f.bpm, masterBpm);
      if ((deck.tempo - tempo).abs() > 0.0005) await deck.setTempo(tempo);
      if (deck.loop != null || master.loop != null) {
        await deck.setBend(0);
        continue;
      }
      final error = phaseErrorMs(
        follower: f,
        followerMs: deck.positionMs,
        master: mf,
        masterMs: master.positionMs,
        masterBpm: masterBpm,
      );
      if (error.abs() > 120 || (deck.keyShift != 0 && error.abs() > 40)) {
        // Muy lejos (o con cambio de tonalidad, donde el ajuste fino corta
        // el sonido): salto directo al pulso.
        await deck.setBend(0);
        await _alignPhase(deck, master);
      } else if (deck.keyShift == 0 && error.abs() > 6) {
        // Corrige el desfase en ~1 s.
        await deck.setBend((-error / 1000).clamp(-0.03, 0.03));
      } else {
        await deck.setBend(0);
      }
    }
  }

  /// Sincronizar tonalidad: cambia la de [deck] para que combine con la
  /// del otro en la rueda Camelot (la misma casilla o una vecina).
  Future<String?> syncKey(DjDeck deck) async {
    final f = deck.features;
    final masterKey = other(deck).effectiveKey;
    if (f == null || !f.hasKey || masterKey == null) {
      return 'Hace falta la tonalidad de las dos canciones.';
    }
    final shift = semitonesToMatchKey(f.keyIndex, masterKey);
    if (shift == null) return 'No se pudo calcular la tonalidad.';
    if (!deck.keylock) await deck.setKeylock(true);
    await deck.setKeyShift(shift);
    return null;
  }

  // ---------------------------------------------------------------------
  // Mezcla automática
  // ---------------------------------------------------------------------

  /// Pasa de un deck al otro en [beats] pulsos: sincroniza el que entra, lo
  /// arranca en el próximo compás (alineado) si estaba frenado, mueve el
  /// crossfader de a poco y al final frena el que sale.
  Future<String?> autoMix({int beats = 16}) async {
    if (_mixingTo != null) {
      cancelAutoMix();
      return null;
    }
    final from = crossfader <= 0 ? a : b;
    final to = other(from);
    if (!to.loaded) return 'Cargá una canción en el deck ${to.label}.';
    if (!from.playing) {
      // No hay nada sonando del otro lado: arranca directo el que entra.
      await to.play();
      await _animateCrossfader(identical(to, a) ? -1 : 1, 1500);
      return null;
    }
    final problem = await setAutoSync(to, true);
    final synced = problem == null;
    _mixingTo = to;
    notifyListeners();

    if (!to.playing) {
      final f = from.features;
      final tf = to.features;
      if (synced && f != null && tf != null) {
        // Entra en el primer tiempo del próximo compás del que suena.
        final downbeat = nextDownbeat(f, from.positionMs + 150);
        final waitMs = (downbeat - from.positionMs) / from.tempo;
        await to.seekMs(to.cueMs ?? tf.firstBeatMs);
        await Future<void>.delayed(
            Duration(milliseconds: math.max(0, waitMs.round() - 30)));
      }
      if (_mixingTo != to) return null;
      await to.play();
    }

    final beatMs = from.bpm != null ? 60000 / from.bpm! : 500.0;
    final target = identical(to, a) ? -1.0 : 1.0;
    await _animateCrossfader(target, beats * beatMs);
    if (_mixingTo != to) return null;
    _mixingTo = null;
    await from.pause();
    await setAutoSync(to, false);
    notifyListeners();
    return synced ? null : problem;
  }

  void cancelAutoMix() {
    _mixTimer?.cancel();
    _mixTimer = null;
    _mixingTo = null;
    notifyListeners();
  }

  Future<void> _animateCrossfader(double target, double durationMs) {
    _mixTimer?.cancel();
    final completer = Completer<void>();
    final start = crossfader;
    final clock = Stopwatch()..start();
    _mixTimer = Timer.periodic(const Duration(milliseconds: 40), (timer) {
      final t = (clock.elapsedMilliseconds / durationMs).clamp(0.0, 1.0);
      // Curva suave (arranca y termina despacio).
      final eased = t * t * (3 - 2 * t);
      unawaited(setCrossfader(start + (target - start) * eased));
      if (t >= 1) {
        timer.cancel();
        if (!completer.isCompleted) completer.complete();
      }
    });
    // Si se cancela, igual se completa.
    Timer(Duration(milliseconds: durationMs.round() + 200), () {
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  // ---------------------------------------------------------------------
  // Prueba de salida
  // ---------------------------------------------------------------------

  Player? _tone;
  String? _tonePath;

  /// Salida de audio de los decks: "auto" (la de Windows) o la placa de
  /// un controlador ("wasapi/{id}", ver [DjAudioDevice]).
  String outputDevice = 'auto';

  Future<void> setOutputDevice(String device) async {
    outputDevice = device;
    notifyListeners();
    for (final deck in decks) {
      await deck.setAudioDevice(device);
    }
    final tone = _tone?.platform;
    if (tone is NativePlayer) await tone.setProperty('audio-device', device);
  }

  /// Tres pitidos cortos por el lado de [deck] (A izquierda, B derecha),
  /// para comprobar por dónde sale cada uno antes de mezclar.
  Future<void> testOutput(DjDeck deck) async {
    final player = _tone ??= Player();
    final platform = player.platform;
    _tonePath ??= await _writeTone();
    if (platform is NativePlayer) {
      await platform.setProperty('audio-device', outputDevice);
      await platform.setProperty('af', djSideFilter(deck.label));
    }
    await player.setVolume(70);
    await player.open(Media(_tonePath!), play: true);
  }

  static Future<String> _writeTone() async {
    const rate = 44100;
    const beepMs = 140;
    const gapMs = 110;
    final samples = <int>[];
    for (var beep = 0; beep < 3; beep++) {
      final n = rate * beepMs ~/ 1000;
      for (var i = 0; i < n; i++) {
        // Entrada y salida suaves para que no haga "clic".
        final edge = math.min(1.0, math.min(i, n - i) / (rate * 0.008));
        samples.add(
            (math.sin(2 * math.pi * 1000 * i / rate) * 0.5 * edge * 32767)
                .round());
      }
      samples.addAll(List.filled(rate * gapMs ~/ 1000, 0));
    }
    final data = ByteData(44 + samples.length * 2);
    void text(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        data.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    text(0, 'RIFF');
    data.setUint32(4, 36 + samples.length * 2, Endian.little);
    text(8, 'WAVE');
    text(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, 1, Endian.little); // mono
    data.setUint32(24, rate, Endian.little);
    data.setUint32(28, rate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    text(36, 'data');
    data.setUint32(40, samples.length * 2, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      data.setInt16(44 + i * 2, samples[i], Endian.little);
    }
    final file = File(
        p.join((await getTemporaryDirectory()).path, 'tk_music_dj_prueba.wav'));
    await file.writeAsBytes(data.buffer.asUint8List());
    return file.path;
  }

  // ---------------------------------------------------------------------

  void _reportToSystem() {
    final deck = masterDeck ?? _lastPlaying;
    final song = deck?.song;
    final main = _main;
    if (main == null || deck == null || song == null) return;
    main.reportExternalState(
      title: song.title,
      artist: song.artist,
      filePath: song.filePath,
      // Sin id de biblioteca a propósito: con id, el reproductor principal
      // se pone a analizar su propia forma de onda de esta canción, y el
      // análisis nativo (de a un pedido) cancelaba el del otro deck.
      playing: decks.any((d) => d.playing),
      position: Duration(milliseconds: deck.positionMs.round()),
      duration: deck.durationMs > 0
          ? Duration(milliseconds: deck.durationMs.round())
          : null,
    );
  }

  @override
  void dispose() {
    unawaited(_tone?.dispose());
    _syncTimer.cancel();
    _mixTimer?.cancel();
    for (final deck in decks) {
      deck.removeListener(_onDeckChanged);
      deck.dispose();
    }
    _main?.releaseExternalControl();
    super.dispose();
  }
}
