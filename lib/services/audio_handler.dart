import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'active_profile.dart';
import 'artwork_cache.dart';
import 'equalizer_store.dart';
import 'favorites_store.dart';
import 'recent_songs_store.dart';

class MyAudioHandler extends BaseAudioHandler with SeekHandler {
  // El equalizer tiene que existir ANTES de crear _player, porque se lo
  // engancha en su audioPipeline al construirlo — no se puede sumar un
  // efecto de audio a un AudioPlayer ya creado.
  final _equalizer = AndroidEqualizer();
  late final _player =
      AudioPlayer(audioPipeline: AudioPipeline(androidAudioEffects: [_equalizer]));
  final _equalizerStore = EqualizerStore();
  final _artwork = ArtworkCache();
  final _recentSongs = RecentSongsStore();

  /// Para la pantalla del Ecualizador: bandas de frecuencia y su ganancia,
  /// vía el efecto nativo de Android (no hace falta código nativo propio).
  AndroidEqualizer get equalizer => _equalizer;

  // Singleton: la pantalla de Favoritos escucha al mismo objeto, así que
  // marcar "me gusta" desde la notificación se refleja ahí en vivo.
  final _favorites = FavoritesStore.instance;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  Timer? _sleepTimer;

  /// Hora en la que se pausará por el temporizador de apagado, o `null` si
  /// no hay uno activo. Las pantallas lo escuchan directamente.
  final ValueNotifier<DateTime?> sleepTimerEndsAt = ValueNotifier(null);

  // _transformEvent reconstruye el PlaybackState entero en cada evento del
  // reproductor (varias veces por segundo mientras suena), así que estos
  // tres datos se cachean en memoria en vez de leerse del propio
  // PlaybackState: si no, cada rebuild los pisaría con sus valores por
  // defecto y el estado de shuffle/repeat/me-gusta se vería resetear solo.
  AudioServiceShuffleMode _shuffleMode = AudioServiceShuffleMode.none;
  AudioServiceRepeatMode _repeatMode = AudioServiceRepeatMode.none;
  bool _currentLiked = false;

  // El Mezclador automático tiene sus propios reproductores (necesita dos
  // para el crossfade) y por eso no pasa por acá — pero eso significa que,
  // sin esto, Android no tiene ningún motivo para mantener el proceso vivo
  // en segundo plano mientras suena (no hay notificación/sesión de medios
  // activa reflejando esa reproducción). Con esto, el Automix "toma
  // prestada" esta sesión: la notificación pasa a mostrar lo que suena ahí
  // y sus botones de play/pausa/stop se redirigen de vuelta al Automix, sin
  // tener que duplicar todo este pipeline para un segundo motor de audio.
  bool _externalControlActive = false;
  Future<void> Function()? _externalPlay;
  Future<void> Function()? _externalPause;
  Future<void> Function()? _externalStop;
  Future<void> Function()? _externalSkipNext;

  MyAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    final session = await AudioSession.instance;
    // AudioSessionConfiguration.music() pide foco de audio exclusivo
    // (AndroidAudioFocusGainType.gain), que Android le niega a la app
    // mientras hay una llamada activa (WhatsApp, etc.) — por eso tocar play
    // no hacía nada durante una llamada. Con "duck" se pide poder sonar de
    // fondo con el volumen bajo en vez de pedir el control exclusivo, igual
    // que hacen apps como YouTube Music.
    await session.configure(const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionMode: AVAudioSessionMode.defaultMode,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
    ));

    _subscriptions.add(
      session.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              // Bajar el volumen en vez de pausar (p. ej. notificaciones o
              // llamadas que solo piden convivir, no el control exclusivo).
              _player.setVolume(0.3);
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              pause();
              break;
          }
        } else {
          _player.setVolume(1.0);
        }
      }),
    );
    _subscriptions.add(
      session.becomingNoisyEventStream.listen((_) => pause()),
    );
    _subscriptions.add(
      _player.playbackEventStream.listen((event) {
        // Mientras el Automix tiene el control, este reproductor está
        // pausado a propósito — no hay que dejar que su stream pise el
        // estado que el Automix está reportando.
        if (_externalControlActive) return;
        playbackState.add(_transformEvent(event));
      }),
    );
    _subscriptions.add(
      _player.currentIndexStream.listen(_onIndexChanged),
    );

    await _applySavedEqualizer();
  }

  /// El efecto nativo arranca "plano" en cada instancia nueva del
  /// reproductor — acá se reaplica lo que el usuario haya dejado guardado
  /// la última vez. Envuelto en try/catch porque no todos los dispositivos
  /// Android soportan el efecto Equalizer; si falla, la app sigue andando
  /// sin él en vez de trabarse en el arranque.
  Future<void> _applySavedEqualizer() async {
    try {
      final enabled = await _equalizerStore.getEnabled();
      await _equalizer.setEnabled(enabled);
      final gains = await _equalizerStore.getGains();
      if (gains.isEmpty) return;
      final params = await _equalizer.parameters;
      for (final band in params.bands) {
        final saved = gains[band.index];
        if (saved != null) await band.setGain(saved);
      }
    } catch (_) {
      // Sin ecualizador disponible en este dispositivo: no rompe nada.
    }
  }

  void _onIndexChanged(int? index) {
    final items = queue.value;
    if (index == null || index >= items.length) return;
    final item = items[index];
    mediaItem.add(item);
    _attachArtwork(index);

    final songId = item.extras?['songId'] as int?;
    if (songId != null) {
      _recentSongs.recordPlayed(songId);
      _refreshLikedState(songId);
    }
  }

  Future<void> _refreshLikedState(int songId) async {
    _currentLiked = await _favorites.isLiked(songId);
    playbackState.add(_transformEvent(_player.playbackEvent));
  }

  /// La carátula se resuelve al vuelo: consultarla para toda la biblioteca al
  /// cargar sería demasiado lento.
  Future<void> _attachArtwork(int index) async {
    final items = queue.value;
    if (index >= items.length) return;

    final item = items[index];
    if (item.artUri != null) return;

    final songId = item.extras?['songId'] as int?;
    if (songId == null) return;

    final uri = await _artwork.uriFor(songId);
    if (uri == null) return;

    // La cola pudo cambiar mientras se leía la carátula.
    final current = queue.value;
    if (index >= current.length || current[index].id != item.id) return;

    final updated = item.copyWith(artUri: uri);
    queue.add(List<MediaItem>.from(current)..[index] = updated);
    if (mediaItem.value?.id == updated.id) mediaItem.add(updated);
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.custom(
          androidIcon: _currentLiked
              ? 'drawable/ic_thumb_up_filled'
              : 'drawable/ic_thumb_up_outline',
          label: _currentLiked ? 'Quitar me gusta' : 'Me gusta',
          name: 'like',
        ),
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.custom(
          androidIcon: 'drawable/ic_shuffle',
          label: 'Aleatorio',
          name: 'shuffle',
        ),
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      // Vista compacta de la notificación: anterior / play-pausa / siguiente.
      androidCompactActionIndices: const [1, 2, 3],
      playing: _player.playing,
      processingState: {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: event.currentIndex,
      shuffleMode: _shuffleMode,
      repeatMode: _repeatMode,
    );
  }

  @override
  Future<void> play() {
    if (_externalControlActive) return _externalPlay?.call() ?? Future.value();
    return _player.play();
  }

  @override
  Future<void> pause() async {
    if (_externalControlActive) {
      await _externalPause?.call();
      return;
    }
    await _player.pause();
    await _savePosition();
  }

  @override
  Future<void> stop() async {
    if (_externalControlActive) {
      await _externalStop?.call();
      return;
    }
    await _savePosition();
    await _player.stop();
    mediaItem.add(null);
    await super.stop();
  }

  /// Usado por el Mezclador automático: silencia este reproductor (para no
  /// competir por audio con los suyos) y redirige los comandos de la
  /// notificación (play/pausa/siguiente/stop) hacia
  /// [onPlay]/[onPause]/[onSkipNext]/[onStop]. La notificación en sí se
  /// actualiza llamando a [reportExternalState].
  void takeExternalControl({
    required Future<void> Function() onPlay,
    required Future<void> Function() onPause,
    required Future<void> Function() onStop,
    Future<void> Function()? onSkipNext,
  }) {
    _player.pause();
    _externalControlActive = true;
    _externalPlay = onPlay;
    _externalPause = onPause;
    _externalStop = onStop;
    _externalSkipNext = onSkipNext;
  }

  /// Devuelve la notificación al reproductor principal, tal como haya
  /// quedado (pausado, en la canción en la que estaba antes del Automix).
  void releaseExternalControl() {
    if (!_externalControlActive) return;
    _externalControlActive = false;
    _externalPlay = null;
    _externalPause = null;
    _externalStop = null;
    _externalSkipNext = null;

    final index = _player.currentIndex;
    final items = queue.value;
    if (index != null && index < items.length) {
      mediaItem.add(items[index]);
    } else {
      // No hay una canción real a la que volver (p. ej. se entró al
      // Automix sin haber reproducido nada antes en la sesión): mejor
      // limpiar que dejar pegada la info del Automix.
      mediaItem.add(null);
    }
    playbackState.add(_transformEvent(_player.playbackEvent));
  }

  /// El Mezclador automático llama esto en cada cambio relevante (cambio de
  /// canción, cruce, play/pausa) para que la notificación se mantenga al
  /// día con lo que está sonando ahí. No hace falta llamarlo en cada tick
  /// de posición: Android extrapola la barra de progreso sola a partir de
  /// [position] + [playing], igual que con la reproducción normal.
  ///
  /// [filePath]/[mediaStoreId] son los reales de la canción (viene de tu
  /// biblioteca, las canciones del Automix salen de una playlist real) —
  /// con eso se puede traer la carátula real igual que en la reproducción
  /// normal, y las pantallas que dependen de "songId" (carátula, onda) dejan
  /// de verlo como una canción sin datos.
  ///
  /// El `id` del MediaItem tiene que ser la ruta real, no un string
  /// inventado: Android puede intentar "reanudar" la sesión usando ese id
  /// como si fuera un archivo (p. ej. desde los controles rápidos del
  /// sistema), y con un id inventado eso fallaba con
  /// "Failed to open file 'automix:...'".
  void reportExternalState({
    required String title,
    String? artist,
    required String filePath,
    int? mediaStoreId,
    required bool playing,
    required Duration position,
    Duration? duration,
  }) {
    if (!_externalControlActive) return;
    final item = MediaItem(
      id: filePath,
      title: title,
      artist: artist,
      duration: duration,
      extras: mediaStoreId != null ? {'songId': mediaStoreId} : null,
    );
    mediaItem.add(item);
    if (mediaStoreId != null) {
      unawaited(_attachExternalArtwork(mediaStoreId, item));
    }

    playbackState.add(PlaybackState(
      controls: [
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      playing: playing,
      processingState: AudioProcessingState.ready,
      updatePosition: position,
      speed: 1.0,
    ));
  }

  /// La notificación del sistema (a diferencia de los widgets propios, que
  /// consultan la carátula directo por songId) necesita el `artUri` puesto
  /// en el propio MediaItem para poder mostrarla.
  Future<void> _attachExternalArtwork(int mediaStoreId, MediaItem base) async {
    final uri = await _artwork.uriFor(mediaStoreId);
    if (uri == null) return;
    if (!_externalControlActive || mediaItem.value?.id != base.id) return;
    mediaItem.add(base.copyWith(artUri: uri));
  }

  /// Por defecto, audio_service llama a stop() cuando el usuario desliza la
  /// notificación para cerrarla (pausada, deja de ser "ongoing" y se puede
  /// descartar). Eso da de baja toda la sesión con el sistema, y después
  /// tocar una canción ya no logra que la notificación vuelva a aparecer.
  /// Se deja vacío para que descartar la notificación no afecte a la
  /// reproducción: si el usuario vuelve a tocar play, todo sigue igual.
  @override
  Future<void> onNotificationDeleted() async {}

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() {
    if (_externalControlActive) {
      return _externalSkipNext?.call() ?? Future.value();
    }
    return _player.seekToNext();
  }

  @override
  Future<void> skipToPrevious() => _player.seekToPrevious();

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= queue.value.length) return;
    await _player.seek(Duration.zero, index: index);
  }

  /// Reordena la cola actual (pantalla "A continuación"). La posición que
  /// esté sonando se sigue reproduciendo sin cortes, solo cambia el orden.
  Future<void> moveQueueItem(int oldIndex, int newIndex) async {
    final items = List<MediaItem>.from(queue.value);
    if (oldIndex < 0 ||
        oldIndex >= items.length ||
        newIndex < 0 ||
        newIndex >= items.length) {
      return;
    }
    await _player.moveAudioSource(oldIndex, newIndex);
    final item = items.removeAt(oldIndex);
    items.insert(newIndex, item);
    queue.add(items);
  }

  /// Saca una canción de la cola actual sin borrarla de la biblioteca.
  @override
  Future<void> removeQueueItemAt(int index) async {
    final items = List<MediaItem>.from(queue.value);
    if (index < 0 || index >= items.length) return;
    await _player.removeAudioSourceAt(index);
    items.removeAt(index);
    queue.add(items);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    await _player.setShuffleModeEnabled(
        shuffleMode == AudioServiceShuffleMode.all ||
            shuffleMode == AudioServiceShuffleMode.group);
    _shuffleMode = shuffleMode;
    playbackState.add(_transformEvent(_player.playbackEvent));
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await _player.setLoopMode(switch (repeatMode) {
      AudioServiceRepeatMode.one => LoopMode.one,
      AudioServiceRepeatMode.all => LoopMode.all,
      _ => LoopMode.off,
    });
    _repeatMode = repeatMode;
    playbackState.add(_transformEvent(_player.playbackEvent));
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    switch (name) {
      case 'like':
        final songId = mediaItem.value?.extras?['songId'] as int?;
        if (songId == null) return;
        _currentLiked = await _favorites.toggle(songId);
        playbackState.add(_transformEvent(_player.playbackEvent));
        break;
      case 'shuffle':
        await setShuffleMode(_shuffleMode == AudioServiceShuffleMode.all
            ? AudioServiceShuffleMode.none
            : AudioServiceShuffleMode.all);
        break;
    }
  }

  /// Arma la cola con [items] y salta a [startIndex]. Con
  /// [resumeLastPosition] en `true` (solo se usa al abrir la app), si hay
  /// una posición guardada de una canción que está en [items] se abre ahí
  /// en vez de en [startIndex] — para retomar donde se dejó la última vez.
  /// El resto de las pantallas (Biblioteca, Buscar, Favoritos, Accesos
  /// directos, playlists, álbumes/artistas) llaman esto con el valor por
  /// defecto para que tocar una canción siempre reproduzca esa canción, sin
  /// que una posición guardada vieja la pise.
  // Se incrementa en cada llamada a setQueue(). Si el usuario toca una
  // canción nueva (desde cualquier pantalla) mientras la anterior todavía
  // está cargando, la llamada vieja reconoce que quedó superada al
  // despertar de su propio await y no llega a pisar el estado que ya dejó
  // la más nueva — así nunca "ganan" dos canciones a la vez ni se cruzan.
  int _queueRequestId = 0;

  Future<void> setQueue(
    List<MediaItem> items, {
    int startIndex = 0,
    bool resumeLastPosition = false,
  }) async {
    // Si el Mezclador automático tiene el control tomado y desde cualquier
    // pantalla se elige una canción individual, hay que cortarlo primero:
    // si no, esto cargaba la cola igual pero play() se seguía redirigiendo
    // al Automix (que no se enteraba de nada), así que no sonaba lo que se
    // acababa de tocar y el Automix seguía como si nada.
    if (_externalControlActive) {
      await _externalStop?.call();
    }

    final requestId = ++_queueRequestId;

    var initialIndex = startIndex;
    int? resumePositionMs;

    if (resumeLastPosition) {
      final prefs = await SharedPreferences.getInstance();
      final savedPath = prefs.getString(_lastSongPathKey);
      final savedPosition = prefs.getInt(_lastSongPositionKey);
      final savedIndex =
          savedPath == null ? -1 : items.indexWhere((item) => item.id == savedPath);
      if (savedIndex >= 0) {
        initialIndex = savedIndex;
        resumePositionMs = savedPosition;
      }
    }

    if (requestId != _queueRequestId) return;
    queue.add(items);

    await _player.setAudioSources(
      items.map((item) => AudioSource.uri(_sourceUri(item.id))).toList(),
      initialIndex: initialIndex,
    );

    // Llegó otro pedido mientras este todavía cargaba: este ya murió, que
    // gane el más nuevo.
    if (requestId != _queueRequestId) return;

    mediaItem.add(items[initialIndex]);
    _attachArtwork(initialIndex);
    if (resumePositionMs != null) {
      await _player.seek(Duration(milliseconds: resumePositionMs));
    }
  }

  /// Los `MediaItem.id` de canciones del pendrive son URIs `content://`
  /// (SAF), no rutas de archivo reales — `Uri.file()` los rompería.
  Uri _sourceUri(String id) =>
      id.startsWith('content://') ? Uri.parse(id) : Uri.file(id);

  String get _lastSongPathKey => '${ActiveProfile.instance.key}.lastSongPath';
  String get _lastSongPositionKey =>
      '${ActiveProfile.instance.key}.lastSongPosition';

  Future<void> _savePosition() async {
    final item = mediaItem.value;
    if (item == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSongPathKey, item.id);
    await prefs.setInt(_lastSongPositionKey, _player.position.inMilliseconds);
  }

  /// Pausa la reproducción una vez transcurrido [duration]. Reemplaza
  /// cualquier temporizador ya activo en vez de acumularlos.
  void setSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    sleepTimerEndsAt.value = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, () {
      pause();
      sleepTimerEndsAt.value = null;
    });
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepTimerEndsAt.value = null;
  }

  /// Libera el reproductor. Sólo debe llamarse al terminar el servicio.
  Future<void> dispose() async {
    _sleepTimer?.cancel();
    sleepTimerEndsAt.dispose();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    await _player.dispose();
  }
}
