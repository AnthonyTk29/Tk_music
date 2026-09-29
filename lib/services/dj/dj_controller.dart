import 'dart:async';

import 'package:flutter/foundation.dart';

import 'dj_deck.dart';
import 'dj_math.dart';
import 'dj_mixer.dart';
import 'midi_bridge.dart';

/// Un modelo de controlador DJ conocido.
class DjControllerProfile {
  const DjControllerProfile({
    required this.id,
    required this.displayName,
    required this.shortName,
    required this.hasSoundCard,
  });

  final String id;

  /// "NUMARK MIXTRACK PRO 3" (el cartel de "equipo detectado").
  final String displayName;

  /// "MixTrack PRO 3" (botones y avisos).
  final String shortName;

  /// Trae placa de sonido propia (los parlantes pueden ir conectados a él).
  final bool hasSoundCard;

  /// Si la salida de audio [description] ("Altavoces (Mixtrack Pro 3)") es
  /// la placa de este controlador.
  bool matchesAudio(String description) =>
      _flat(description).contains('mixtrack');
}

String _flat(String text) =>
    text.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

/// Numark Mixtrack Pro 3: el mismo controlador que el Mixtrack 3, con placa
/// de sonido (salidas 1-2 parlantes, 3-4 auriculares).
const mixtrackPro3 = DjControllerProfile(
  id: 'numark-mixtrack-pro-3',
  displayName: 'NUMARK MIXTRACK PRO 3',
  shortName: 'MixTrack PRO 3',
  hasSoundCard: true,
);

const mixtrack3 = DjControllerProfile(
  id: 'numark-mixtrack-3',
  displayName: 'NUMARK MIXTRACK 3',
  shortName: 'MixTrack 3',
  hasSoundCard: false,
);

/// El modelo del controlador MIDI que se llama [midiName], o `null` si no es
/// uno conocido.
DjControllerProfile? profileForMidiName(String midiName) {
  final flat = _flat(midiName);
  if (flat.contains('mixtrackpro3')) return mixtrackPro3;
  if (flat.contains('mixtrack3')) return mixtrack3;
  return null;
}

/// Lo que el controlador le pide a la pantalla.
class DjControllerActions {
  const DjControllerActions({
    required this.onPadMode,
    required this.onLoad,
    required this.onMessage,
  });

  /// Botón PAD MODE: pasar los pads de ese deck al modo siguiente.
  final void Function(DjDeck deck) onPadMode;

  /// LOAD (o PLAY sin canción): abrir el gestor de archivos para ese deck
  /// (`null` = el botón del navegador, sin deck).
  final void Function(DjDeck? deck) onLoad;

  /// Un aviso para mostrar (sync que no se pudo, etc.).
  final void Function(String message) onMessage;
}

/// Una línea del monitor MIDI: lo que llegó y qué hizo.
class MidiLogEntry {
  MidiLogEntry(this.raw, this.action);
  final String raw;
  final String action;
}

/// Qué hace cada control del Mixtrack (Pro) 3 en TK Music, para mostrarlo.
const mixtrackControlHelp = <(String, String)>[
  (
    'PLAY',
    'Arranca o frena. Sin canción, abre los archivos. SHIFT: vuelve al CUE y sigue.'
  ),
  (
    'CUE',
    'Sonando: vuelve al CUE y frena. Frenado: lo marca; si ya está en el CUE, mantenelo apretado para escuchar desde ahí.'
  ),
  (
    'SYNC',
    'Iguala el BPM y alinea los pulsos. SHIFT: sincronía automática (AUTO).'
  ),
  (
    'Plato (arriba)',
    'Tocándolo: mueve la canción, como un vinilo. Con la canción frenada también.'
  ),
  (
    'Plato (costado)',
    'Sonando: la apura o la frena un instante para emparejar a oído.'
  ),
  (
    'Botón del plato (SCRATCH)',
    'Si está prendido, tocar el plato arriba mueve la canción aunque esté sonando.'
  ),
  (
    'PITCH BEND − / +',
    'Frena o apura mientras lo mantenés. SHIFT: salta 4 pulsos.'
  ),
  (
    'Fader de pitch',
    'Velocidad del deck dentro del rango elegido en pantalla.'
  ),
  (
    'Pads (modo CUE)',
    'Puntos 1 a 4: si está vacío lo guarda, si no salta ahí. SHIFT: lo borra.'
  ),
  ('Pads (modo AUTO LOOP)', 'Bucle de 2, 4, 8 y 16 pulsos.'),
  (
    'Pads (modo SAMPLE)',
    'Saltos de −4, −1, +1 y +4 pulsos (TK Music no tiene sampler).'
  ),
  ('LOOP IN / LOOP OUT', 'Bucle manual: marca dónde empieza y dónde termina.'),
  ('RELOOP / EXIT', 'Sale del bucle, o vuelve a activar el último.'),
  ('LOOP ½', 'Bucle a la mitad. SHIFT: al doble.'),
  (
    'PAD MODE',
    'Cambia el modo de los pads en pantalla (PUNTOS, BUCLE, SALTO).'
  ),
  ('TAP', 'Sincroniza la tonalidad (TONO). SHIFT: tonalidad original.'),
  ('HIGH / MID / LOW', 'Agudos, medios y graves del deck.'),
  ('FILTER', 'GANANCIA del deck (TK Music no tiene filtro).'),
  ('Fader de canal', 'Volumen del deck.'),
  ('Crossfader', 'Pasa de un deck al otro (cancela la mezcla automática).'),
  (
    'MASTER (perilla)',
    'Volumen GENERAL (al medio, 0 dB; a la derecha potencia hasta +6 dB).'
  ),
  ('LOAD A / LOAD B', 'Abre el gestor de archivos para cargar en ese deck.'),
  ('BROWSE (apretar)', 'Abre el gestor de archivos.'),
  (
    'Sin función por ahora',
    'FX 1-3, BEAT, TOUCH STRIP, BROWSE (girar), CUE de auriculares, CUE GAIN y CUE MIX.'
  ),
];

/// El Numark Mixtrack (Pro) 3 manejando los decks. Los números de cada
/// control y de cada luz son los del controlador (los mismos que usa el
/// mapeo libre de Mixxx): deck A = canal MIDI 2 (0x91/0xB1), deck B = canal
/// 3 (0x92/0xB2), el resto = canal 1 (0x90/0xB0). Los botones mandan 0x7F
/// al apretar y 0x00 al soltar.
class MixtrackMapping extends ChangeNotifier {
  MixtrackMapping({
    required this.mixer,
    required this.send,
    required this.actions,
    this.invertPitch = false,
  });

  final DjMixer mixer;
  final Future<void> Function(List<int> bytes) send;
  final DjControllerActions actions;

  /// Si el fader de pitch va al revés de lo esperado (arriba = más rápido).
  bool invertPitch;

  final _shift = [false, false];
  final _scratch = [false, false];
  final _touch = [false, false];
  final _cuePreview = [false, false];
  final _pitchMsb = [64, 64];
  final _bendTimers = <Timer?>[null, null];
  final _jogPending = [0.0, 0.0];
  final _jogTimers = <Timer?>[null, null];

  /// Toma suave: un fader o perilla no manda hasta que su posición física
  /// alcanza la de la pantalla (si no, el volumen pegaría un salto).
  final _lastIncoming = <int, double>{};
  final _owned = <int, double>{};

  final _lights = <int, int>{};
  Timer? _meterTimer;
  Timer? _logTimer;
  bool _started = false;

  /// Últimos mensajes y qué hizo cada uno (el más nuevo primero).
  final log = <MidiLogEntry>[];

  static const _loopBeats = [2.0, 4.0, 8.0, 16.0];
  static const _jumpBeats = [-4.0, -1.0, 1.0, 4.0];

  // -------------------------------------------------------------------------
  // Entrada
  // -------------------------------------------------------------------------

  /// Procesa una tanda [status, d1, d2, …] del controlador.
  void handleBatch(List<int> bytes) {
    for (var i = 0; i + 2 < bytes.length; i += 3) {
      handle(bytes[i], bytes[i + 1], bytes[i + 2]);
    }
  }

  void handle(int status, int d1, int d2) {
    final type = status & 0xF0;
    final channel = status & 0x0F;
    final isNote = type == 0x90 || type == 0x80;
    final value = type == 0x80 ? 0 : d2;
    String? action;
    if (channel == 1 || channel == 2) {
      final deck = mixer.decks[channel - 1];
      if (isNote) {
        action = _deckNote(deck, channel - 1, d1, value > 0);
      } else if (type == 0xB0) {
        action = _deckControl(deck, channel - 1, d1, value);
      }
    } else if (channel == 0) {
      if (isNote) {
        action = _masterNote(d1, value > 0);
      } else if (type == 0xB0) {
        action = _masterControl(d1, value);
      }
    }
    _addLog(status, d1, d2, action);
  }

  String? _deckNote(DjDeck deck, int i, int note, bool down) {
    final name = 'Deck ${deck.label}';
    switch (note) {
      case 0x0B:
        _shift[i] = down;
        return down ? '$name · SHIFT' : null;
      case 0x01:
        if (!down) return null;
        if (!deck.loaded) {
          actions.onLoad(deck);
          return '$name · PLAY sin canción: abrir archivos';
        }
        if (_shift[i]) {
          unawaited(deck.seekMs(deck.cueMs ?? 0).then((_) => deck.play()));
          return '$name · volver al CUE y seguir';
        }
        unawaited(deck.togglePlay());
        return '$name · PLAY';
      case 0x03:
        return _cueButton(deck, i, down);
      case 0x02:
        if (!down || !deck.loaded) return null;
        if (_shift[i]) {
          unawaited(
              mixer.setAutoSync(deck, !deck.autoSync).then((m) => _say(m)));
          return '$name · AUTO';
        }
        unawaited(mixer.sync(deck).then(_say));
        return '$name · SYNC';
      case 0x04:
      case 0x05:
        final sign = note == 0x05 ? 1.0 : -1.0;
        if (down && _shift[i]) {
          unawaited(deck.beatJump(4 * sign));
          return '$name · saltar ${sign > 0 ? '+' : '−'}4 pulsos';
        }
        if (deck.autoSync) return null;
        unawaited(deck.setBend(down ? 0.04 * sign : 0));
        return down ? '$name · pitch bend ${sign > 0 ? '+' : '−'}' : null;
      case 0x06:
        if (!down) return null;
        _scratch[i] = !_scratch[i];
        _refreshLights();
        return '$name · SCRATCH ${_scratch[i] ? 'prendido' : 'apagado'}';
      case 0x0C:
        _touch[i] = down;
        if (!down) {
          _flushJog(deck, i);
          if (!deck.autoSync) unawaited(deck.setBend(0));
        }
        return null;
      case 0x0D:
        if (!down) return null;
        actions.onPadMode(deck);
        return '$name · PAD MODE';
      case 0x0A:
        if (!down || !deck.loaded) return null;
        if (_shift[i]) {
          unawaited(deck.setKeyShift(0));
          return '$name · tonalidad original';
        }
        unawaited(mixer.syncKey(deck).then(_say));
        return '$name · TONO';
      case 0x13:
        if (!down) return null;
        deck.markLoopIn();
        return '$name · LOOP IN';
      case 0x14:
        if (!down) return null;
        unawaited(deck.markLoopOut());
        return '$name · LOOP OUT';
      case 0x15:
        if (!down) return null;
        unawaited(deck.reloop());
        return '$name · RELOOP / EXIT';
      case 0x16:
        if (!down) return null;
        unawaited(_shift[i] ? deck.doubleLoop() : deck.halveLoop());
        return '$name · bucle ${_shift[i] ? '×2' : '½'}';
      case >= 0x17 && <= 0x1A:
        if (!down) return null;
        final beats = _loopBeats[note - 0x17];
        unawaited(deck.toggleLoop(beats));
        return '$name · bucle de ${beats.toInt()} pulsos';
      case >= 0x1B && <= 0x1E:
        if (!down) return null;
        final index = note - 0x1B;
        if (_shift[i]) {
          deck.clearHotCue(index);
          return '$name · borrar punto ${index + 1}';
        }
        unawaited(deck.hotCue(index));
        return '$name · punto ${index + 1}';
      case >= 0x20 && <= 0x23:
        if (!down) return null;
        final beats = _jumpBeats[note - 0x20];
        unawaited(deck.beatJump(beats));
        return '$name · saltar ${beats > 0 ? '+' : ''}${beats.toInt()} pulsos';
    }
    return down ? '$name · sin función' : null;
  }

  /// CUE como en una bandeja: sonando vuelve y frena; frenado en el CUE,
  /// mantenerlo apretado lo hace sonar y al soltar vuelve.
  String? _cueButton(DjDeck deck, int i, bool down) {
    final name = 'Deck ${deck.label}';
    if (!down) {
      if (_cuePreview[i]) {
        _cuePreview[i] = false;
        unawaited(deck.pause().then((_) => deck.seekMs(deck.cueMs ?? 0)));
      }
      return null;
    }
    if (!deck.loaded) return null;
    if (_shift[i]) {
      unawaited(deck.seekMs(0));
      return '$name · al comienzo';
    }
    final cue = deck.cueMs;
    if (!deck.playing && cue != null && (deck.positionMs - cue).abs() < 40) {
      _cuePreview[i] = true;
      unawaited(deck.play());
      return '$name · CUE (escuchando mientras lo mantenés)';
    }
    unawaited(deck.cue());
    return '$name · CUE';
  }

  String? _deckControl(DjDeck deck, int i, int cc, int value) {
    final name = 'Deck ${deck.label}';
    final key = ((i + 1) << 8) | cc;
    final n = value / 127;
    switch (cc) {
      case 0x01:
      case 0x02:
      case 0x03:
        // 0x01 agudos, 0x02 medios, 0x03 graves.
        final band = 3 - cc;
        if (!_takeover(key, n, eqToNorm(deck.eq[band]))) return null;
        unawaited(deck.setEq(band, eqFromNorm(n)));
        return '$name · ${const ['GRAVES', 'MEDIOS', 'AGUDOS'][band]}';
      case 0x04:
        if (!_takeover(key, n, gainToNorm(deck.gainDb))) return null;
        unawaited(deck.setGain(gainFromNorm(n)));
        return '$name · GANANCIA';
      case 0x05:
        if (!_takeover(key, n, deck.volume)) return null;
        unawaited(deck.setVolume(n));
        return '$name · volumen';
      case 0x11:
        _jog(deck, i, value > 63 ? value - 128 : value);
        return null;
      case 0x18:
        _pitchMsb[i] = value;
        return null;
      case 0x38:
        final raw = (_pitchMsb[i] * 128 + value) / 16383;
        final current = _pitchToNorm(deck);
        if (!_takeover(key, raw, current)) return null;
        unawaited(deck.setPitch(_pitchFromNorm(deck, raw)));
        return '$name · pitch';
    }
    return null;
  }

  String? _masterNote(int note, bool down) {
    if (!down) return null;
    switch (note) {
      case 0x10:
        actions.onLoad(mixer.a);
        return 'LOAD A';
      case 0x11:
        actions.onLoad(mixer.b);
        return 'LOAD B';
      case 0x12:
        actions.onLoad(null);
        return 'BROWSE';
    }
    return 'sin función';
  }

  String? _masterControl(int cc, int value) {
    final n = value / 127;
    switch (cc) {
      case 0x07:
        if (!_takeover(cc, n, (mixer.crossfader + 1) / 2)) return null;
        if (mixer.mixingTo != null) mixer.cancelAutoMix();
        unawaited(mixer.setCrossfader(n * 2 - 1));
        return 'Crossfader';
      case 0x0A:
        if (!_takeover(cc, n, masterToNorm(mixer.master))) return null;
        unawaited(mixer.setMaster(masterFromNorm(n)));
        return 'GENERAL';
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Plato
  // -------------------------------------------------------------------------

  /// El plato manda 1200 pasos por vuelta; una vuelta = 1,8 s de canción
  /// (33⅓ rpm), igual que el plato de la pantalla.
  void _jog(DjDeck deck, int i, int delta) {
    if (!deck.loaded || delta == 0) return;
    final moveSong = !deck.playing || (_touch[i] && _scratch[i]);
    if (moveSong) {
      _jogPending[i] += delta * 1.5;
      // Muchos pasos por segundo: se agrupan para no ahogar al reproductor.
      _jogTimers[i] ??= Timer(const Duration(milliseconds: 30), () {
        _jogTimers[i] = null;
        _flushJog(deck, i);
      });
      return;
    }
    if (deck.autoSync) return;
    final bend = (delta.sign * 0.02 * delta.abs().clamp(1, 16) / 4)
        .clamp(-0.08, 0.08)
        .toDouble();
    unawaited(deck.setBend(bend));
    _bendTimers[i]?.cancel();
    _bendTimers[i] = Timer(const Duration(milliseconds: 90), () {
      if (!deck.autoSync) unawaited(deck.setBend(0));
    });
  }

  void _flushJog(DjDeck deck, int i) {
    final ms = _jogPending[i];
    _jogPending[i] = 0;
    if (ms != 0) unawaited(deck.seekMs(deck.positionMs + ms));
  }

  // -------------------------------------------------------------------------
  // Toma suave y conversiones
  // -------------------------------------------------------------------------

  bool _takeover(int key, double incoming, double current) {
    final owned = _owned[key];
    final last = _lastIncoming[key];
    _lastIncoming[key] = incoming;
    // Si nadie lo movió desde la pantalla, el control sigue siendo nuestro.
    final ours = owned != null && (owned - current).abs() < 0.02;
    final near = (incoming - current).abs() <= 0.04;
    final crossed =
        last != null && (last - current).sign != (incoming - current).sign;
    if (ours || near || crossed) {
      _owned[key] = incoming;
      return true;
    }
    return false;
  }

  double _pitchToNorm(DjDeck deck) {
    final r = deck.range == 0 ? 0 : deck.pitch / deck.range;
    // Por defecto: arriba (0) = más lento, abajo (16383) = más rápido.
    return ((invertPitch ? -r : r) + 1) / 2;
  }

  double _pitchFromNorm(DjDeck deck, double n) {
    final r = n * 2 - 1;
    return (invertPitch ? -r : r) * deck.range;
  }

  void _say(String? message) {
    if (message != null) actions.onMessage(message);
  }

  // -------------------------------------------------------------------------
  // Luces
  // -------------------------------------------------------------------------

  /// Prende el controlador: todas las luces (así se encienden las de los
  /// modos de pads) y después cada una según el estado.
  Future<void> start() async {
    _started = true;
    for (final l in [mixer, ...mixer.decks]) {
      l.addListener(_refreshLights);
    }
    await send(const [0x90, 0x75, 0x7F]);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!_started) return;
    _lights.clear();
    _refreshLights();
    _meterTimer =
        Timer.periodic(const Duration(milliseconds: 60), (_) => _meters());
  }

  /// Apaga todo (al salir del Modo DJ o desconectar).
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    for (final l in [mixer, ...mixer.decks]) {
      l.removeListener(_refreshLights);
    }
    _meterTimer?.cancel();
    for (final t in [..._bendTimers, ..._jogTimers]) {
      t?.cancel();
    }
    await send(const [0x90, 0x75, 0x00, 0xB0, 0x02, 0x00, 0xB0, 0x03, 0x00]);
  }

  void _refreshLights() {
    if (!_started) return;
    final out = <int>[];
    void light(int status, int note, bool on) {
      final key = (status << 8) | note;
      final value = on ? 0x7F : 0x00;
      if (_lights[key] == value) return;
      _lights[key] = value;
      out.addAll([status, note, value]);
    }

    for (var i = 0; i < 2; i++) {
      final deck = mixer.decks[i];
      final status = 0x91 + i;
      final loop = deck.loop;
      light(status, 0x01, deck.playing);
      light(status, 0x03, deck.cueMs != null);
      light(status, 0x02, deck.autoSync || _synced(deck));
      light(status, 0x06, _scratch[i]);
      light(status, 0x0A, deck.keyShift != 0);
      light(status, 0x13, deck.loopInMs != null || loop != null);
      light(status, 0x14, loop != null);
      light(status, 0x15, loop != null);
      light(status, 0x16, loop != null);
      for (var k = 0; k < 4; k++) {
        light(status, 0x1B + k, deck.hotCues[k] != null);
        light(status, 0x17 + k, loop?.beats == _loopBeats[k]);
        light(status, 0x20 + k, deck.loaded);
      }
    }
    if (out.isNotEmpty) unawaited(send(out));
  }

  bool _synced(DjDeck deck) {
    final other = mixer.other(deck);
    final f = deck.features;
    final theirs = other.bpm;
    if (f == null || !f.hasTempo || theirs == null) return false;
    return (deck.tempo - tempoForSync(f.bpm, theirs)).abs() < 0.001;
  }

  /// Los vúmetros del controlador (0 a 82).
  void _meters() {
    final out = <int>[];
    for (var i = 0; i < 2; i++) {
      final deck = mixer.decks[i];
      final peaks = deck.peaks;
      var level = 0.0;
      if (deck.playing &&
          peaks != null &&
          peaks.isNotEmpty &&
          deck.durationMs > 0) {
        final index = (deck.positionMs / deck.durationMs * (peaks.length - 1))
            .round()
            .clamp(0, peaks.length - 1);
        level = (peaks[index] * deck.outputLevel).clamp(0.0, 1.0);
      }
      final value = (level * 82).round();
      final key = (0xB0 << 8) | (0x02 + i);
      if (_lights[key] == value) continue;
      _lights[key] = value;
      out.addAll([0xB0, 0x02 + i, value]);
    }
    if (out.isNotEmpty) unawaited(send(out));
  }

  // -------------------------------------------------------------------------
  // Monitor
  // -------------------------------------------------------------------------

  void _addLog(int status, int d1, int d2, String? action) {
    if (action == null) return;
    String hex(int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase();
    log.insert(0, MidiLogEntry('${hex(status)} ${hex(d1)} ${hex(d2)}', action));
    if (log.length > 40) log.removeLast();
    _logTimer ??= Timer(const Duration(milliseconds: 120), () {
      _logTimer = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _logTimer?.cancel();
    _meterTimer?.cancel();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Perillas: de 0–1 (posición física) a dB y al revés, con el centro (64)
// en 0 dB como en la pantalla.
// ---------------------------------------------------------------------------

const _center = 64 / 127;

double eqFromNorm(double n) => n <= _center
    ? DjDeck.eqKill * (1 - n / _center)
    : 6 * (n - _center) / (1 - _center);

double eqToNorm(double db) => db <= 0
    ? _center * (1 - db / DjDeck.eqKill)
    : _center + db / 6 * (1 - _center);

double gainFromNorm(double n) => n <= _center
    ? -DjDeck.maxGainDb * (1 - n / _center)
    : DjDeck.maxGainDb * (n - _center) / (1 - _center);

double gainToNorm(double db) => db <= 0
    ? _center * (1 + db / DjDeck.maxGainDb)
    : _center + db / DjDeck.maxGainDb * (1 - _center);

double masterFromNorm(double n) => n <= _center
    ? n / _center
    : 1 + (n - _center) / (1 - _center) * (DjMixer.maxMaster - 1);

double masterToNorm(double m) => m <= 1
    ? m * _center
    : _center + (m - 1) / (DjMixer.maxMaster - 1) * (1 - _center);

// ---------------------------------------------------------------------------
// Conexión: detecta el controlador al enchufarlo
// ---------------------------------------------------------------------------

/// Busca controladores conocidos cada 2 s, los conecta y avisa.
class DjControllerHub extends ChangeNotifier {
  DjControllerHub({
    required this.mixer,
    required this.actions,
    MidiBridge? bridge,
  }) : _bridge = bridge ?? MidiBridge();

  final DjMixer mixer;
  final DjControllerActions actions;
  final MidiBridge _bridge;

  /// Recién conectado (para la ventana de "nuevo dispositivo detectado").
  void Function(DjControllerProfile profile)? onConnected;

  /// Se desenchufó.
  void Function(DjControllerProfile profile)? onDisconnected;

  DjControllerProfile? profile;
  String? midiName;
  bool lights = false;
  MixtrackMapping? mapping;
  bool invertPitch = false;

  Timer? _poll;
  StreamSubscription<List<int>>? _sub;
  String? _failedName;
  bool _checking = false;
  bool _disposed = false;

  bool get connected => mapping != null;

  void start() {
    if (!MidiBridge.supported) return;
    unawaited(_check());
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _check());
  }

  void setInvertPitch(bool value) {
    invertPitch = value;
    mapping?.invertPitch = value;
    notifyListeners();
  }

  Future<void> _check() async {
    if (_checking || _disposed) return;
    _checking = true;
    try {
      final devices = await _bridge.devices();
      final current = midiName;
      if (current != null && !devices.inputs.contains(current)) {
        await _disconnect();
      }
      if (_failedName != null && !devices.inputs.contains(_failedName)) {
        _failedName = null;
      }
      if (connected) return;
      for (final name in devices.inputs) {
        final found = profileForMidiName(name);
        if (found == null || name == _failedName) continue;
        final output = devices.outputs
            .where((o) => profileForMidiName(o) == found)
            .firstOrNull;
        await _connect(name, output, found);
        return;
      }
    } finally {
      _checking = false;
    }
  }

  Future<void> _connect(
      String input, String? output, DjControllerProfile found) async {
    try {
      lights = await _bridge.open(input, output);
    } on MidiException catch (e) {
      _failedName = input;
      actions.onMessage('${found.shortName}: ${e.message}');
      return;
    }
    if (_disposed) return;
    profile = found;
    midiName = input;
    final map = MixtrackMapping(
      mixer: mixer,
      send: _bridge.send,
      actions: actions,
      invertPitch: invertPitch,
    );
    mapping = map;
    _sub = _bridge.messages.listen(map.handleBatch);
    unawaited(map.start());
    notifyListeners();
    onConnected?.call(found);
  }

  Future<void> _disconnect() async {
    final was = profile;
    await _sub?.cancel();
    _sub = null;
    final map = mapping;
    mapping = null;
    profile = null;
    midiName = null;
    if (map != null) {
      await map.stop();
      map.dispose();
    }
    await _bridge.close();
    if (!_disposed) notifyListeners();
    if (was != null) onDisconnected?.call(was);
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    final map = mapping;
    unawaited(_sub?.cancel());
    if (map != null) {
      unawaited(map.stop().then((_) => _bridge.close()));
      map.dispose();
    }
    super.dispose();
  }
}
