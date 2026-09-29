import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tk_music/domain/entities/song_id.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/services/track_features.dart';
import 'package:tk_music/services/track_features_store.dart';

import 'dj_deck.dart';
import 'dj_mixer.dart';

/// Una canción de la lista del Auto DJ (con id propio: la misma canción
/// puede estar dos veces).
class AutoDjItem {
  AutoDjItem(this.song) : id = _nextId++;
  static int _nextId = 0;

  final int id;
  final Song song;

  /// Ya sonó (se muestra apagada).
  bool played = false;
}

/// Auto DJ del Modo DJ: una lista armada a mano que suena sola, mezclando
/// una canción con la siguiente como lo haría un DJ. Carga la próxima en el
/// deck que está libre y, cuando a la que suena le queda lo justo para la
/// mezcla, usa la mezcla automática del mezclador: sincroniza, entra en el
/// próximo compás y mueve el crossfader en [beats] pulsos.
class DjAutoDj extends ChangeNotifier {
  DjAutoDj(this.mixer, {this.beats = 16});

  final DjMixer mixer;

  /// Largo de cada mezcla en pulsos (8, 16 o 32).
  int beats;

  final List<AutoDjItem> items = [];

  /// La que está sonando (de la lista), o `null` si todavía no arrancó o
  /// suena algo cargado a mano.
  AutoDjItem? current;

  /// La que está cargada esperando su turno en el otro deck.
  AutoDjItem? loadedNext;

  bool running = false;
  bool mixing = false;

  /// Aviso para mostrar (problemas, "terminó la lista").
  String? message;

  Timer? _timer;
  bool _busy = false;

  static const _prefsKey = 'dj.autoDjList';

  /// Margen para empezar la mezcla antes de que termine la canción.
  static const _leadMs = 1500;

  // -------------------------------------------------------------------------
  // Lista
  // -------------------------------------------------------------------------

  /// La lista guardada la vez pasada (las que ya no existen se saltean).
  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return;
      final list = jsonDecode(raw) as List;
      items
        ..clear()
        ..addAll([
          for (final entry in list.cast<Map<String, dynamic>>())
            if (File(entry['path'] as String).existsSync())
              AutoDjItem(Song(
                mediaStoreId: stableSongId(entry['path'] as String),
                title: entry['title'] as String? ??
                    p.basenameWithoutExtension(entry['path'] as String),
                artist: entry['artist'] as String?,
                filePath: entry['path'] as String,
              )),
        ]);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _prefsKey,
          jsonEncode([
            for (final item in items)
              {
                'path': item.song.filePath,
                'title': item.song.title,
                if (item.song.artist != null) 'artist': item.song.artist,
              },
          ]));
    } catch (_) {}
  }

  void add(Iterable<Song> songs) {
    items.addAll(songs.map(AutoDjItem.new));
    notifyListeners();
    unawaited(_save());
    if (running) unawaited(_prepareNext());
  }

  void remove(AutoDjItem item) {
    if (identical(item, current)) return; // la que suena no se saca
    items.remove(item);
    if (identical(item, loadedNext)) loadedNext = null;
    notifyListeners();
    unawaited(_save());
    if (running) unawaited(_prepareNext());
  }

  void move(int from, int to) {
    if (from < 0 || from >= items.length) return;
    final item = items.removeAt(from);
    items.insert(to.clamp(0, items.length), item);
    notifyListeners();
    unawaited(_save());
    if (running) unawaited(_prepareNext());
  }

  void clear() {
    items.removeWhere((item) => !identical(item, current));
    loadedNext = null;
    notifyListeners();
    unawaited(_save());
  }

  /// Vuelve a marcar todas como pendientes (para escuchar la lista de nuevo).
  void resetPlayed() {
    for (final item in items) {
      if (!identical(item, current)) item.played = false;
    }
    notifyListeners();
  }

  /// Ordena lo que falta para que cada canción encadene con la anterior
  /// (ritmo, tonalidad y energía), como el orden inteligente del Mezclador
  /// automático. Analiza las que todavía no tienen BPM.
  Future<void> smartOrder() async {
    final store = TrackFeaturesStore.instance;
    final pending = [
      for (final item in items)
        if (!item.played && !identical(item, current)) item
    ];
    for (final item in pending) {
      await store.featuresFor(item.song.filePath,
          durationMs: item.song.duration?.inMilliseconds);
    }
    TrackFeatures? featuresOf(AutoDjItem item) =>
        store.cached(item.song.filePath);
    final anchor = current;
    final ordered = orderForMixing<AutoDjItem>(
        [if (anchor != null) anchor, ...pending], featuresOf,
        keepFirst: anchor == null ? 0 : 1);
    final rest = ordered.where((item) => !identical(item, anchor)).toList();
    items
      ..removeWhere(pending.contains)
      ..addAll(rest);
    notifyListeners();
    unawaited(_save());
    if (running) unawaited(_prepareNext());
  }

  /// La que sigue: la primera sin sonar después de la actual.
  AutoDjItem? get next {
    final start = current == null ? 0 : items.indexOf(current!) + 1;
    for (var i = start; i < items.length; i++) {
      if (!items[i].played) return items[i];
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Reproducción
  // -------------------------------------------------------------------------

  /// El deck que se escucha: el que está recibiendo la mezcla, o el del
  /// lado del crossfader si suena, o el que suene.
  DjDeck get _onAir {
    final to = mixer.mixingTo;
    if (to != null) return to;
    final side = mixer.crossfader <= 0 ? mixer.a : mixer.b;
    if (side.playing) return side;
    final other = mixer.other(side);
    return other.playing ? other : side;
  }

  /// Arranca: si no suena nada, pone la primera de la lista en el deck del
  /// lado del crossfader y la arranca; después prepara la siguiente.
  Future<String?> start() async {
    if (items.where((i) => !i.played).isEmpty) {
      return 'La lista está vacía (o ya sonó entera).';
    }
    message = null;
    running = true;
    notifyListeners();
    if (!mixer.decks.any((d) => d.playing)) {
      final first = next;
      if (first == null) return null;
      final deck = mixer.crossfader <= 0 ? mixer.a : mixer.b;
      await deck.load(first.song);
      await mixer.setCrossfader(identical(deck, mixer.a) ? -1 : 1);
      current = first;
      first.played = true;
      notifyListeners();
      await deck.play();
    }
    await _prepareNext();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 400), (_) => _tick());
    return null;
  }

  /// Frena el Auto DJ (la música sigue sonando).
  void stop() {
    running = false;
    _timer?.cancel();
    _timer = null;
    notifyListeners();
  }

  /// Mezcla ya con la siguiente, sin esperar el final.
  Future<void> mixNow() async {
    if (!running || mixing) return;
    await _prepareNext();
    await _mix();
  }

  /// Carga la siguiente en el deck que no suena (si todavía no está).
  Future<void> _prepareNext() async {
    if (_busy) return;
    final upcoming = next;
    final free = mixer.other(_onAir);
    if (upcoming == null) {
      loadedNext = null;
      notifyListeners();
      return;
    }
    if (free.playing || mixer.mixingTo != null) return;
    if (identical(loadedNext, upcoming) &&
        free.song?.filePath == upcoming.song.filePath) {
      return;
    }
    _busy = true;
    try {
      await free.load(upcoming.song);
      loadedNext = upcoming;
      notifyListeners();
    } finally {
      _busy = false;
    }
  }

  Future<void> _tick() async {
    if (!running || mixing || _busy) return;
    final deck = _onAir;
    if (!deck.playing || !deck.loaded || deck.durationMs <= 0) {
      // Terminó la última y no hay más: se apaga solo.
      if (next == null && !mixer.decks.any((d) => d.playing)) {
        message = 'Terminó la lista.';
        stop();
      }
      return;
    }
    if (loadedNext == null ||
        mixer.other(deck).song?.filePath != loadedNext!.song.filePath) {
      await _prepareNext();
    }
    final remainingMs = (deck.durationMs - deck.positionMs) / deck.tempo;
    final beatMs = deck.bpm != null ? 60000 / deck.bpm! : 500.0;
    final mixMs = beats * beatMs;
    if (loadedNext != null && remainingMs <= mixMs + _leadMs) {
      await _mix();
    }
  }

  Future<void> _mix() async {
    final incoming = loadedNext;
    if (incoming == null || mixing) return;
    mixing = true;
    notifyListeners();
    final problem = await mixer.autoMix(beats: beats);
    mixing = false;
    current = incoming;
    incoming.played = true;
    loadedNext = null;
    if (problem != null) message = problem;
    notifyListeners();
    if (running) await _prepareNext();
  }

  bool _disposed = false;

  // Una carga o mezcla en curso puede terminar después de cerrar el Modo
  // DJ: ahí ya no hay a quién avisar.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    running = false;
    _timer?.cancel();
    super.dispose();
  }
}
