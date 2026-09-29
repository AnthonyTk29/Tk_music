import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tk_music/core/platform.dart';

import 'active_profile.dart';
import 'app_audio_handler.dart';
import 'crossfade_coordinator.dart';
import 'equalizer_controller.dart';
import 'favorites_store.dart';
import 'recent_songs_store.dart';
import 'windows_media_controls.dart';

/// Reproductor para desktop (Windows/Linux/macOS): el mismo `AudioHandler`
/// que usa el resto de la app (mediaItem/queue/playbackState, play/pause/
/// seek/setQueue — todo lo que las pantallas ya llaman), pero por dentro
/// usa media_kit en vez de just_audio, que no tiene soporte sólido fuera de
/// Android/iOS.
///
/// A propósito NO pasa por `AudioService.init()`: ese es el que engancha la
/// notificación/sesión de medios del sistema operativo, y este paquete no
/// tiene esa integración armada para Windows/Linux. Se construye como un
/// objeto Dart normal y se registra en el service locator igual que
/// `MyAudioHandler`. Lo que en Android hace la notificación, en Windows lo
/// hacen los controles multimedia del sistema ([WindowsMediaControls]).
class DesktopAudioHandler extends BaseAudioHandler
    with SeekHandler
    implements AppAudioHandler {
  final _player = Player();
  final _recentSongs = RecentSongsStore();
  final _favorites = FavoritesStore.instance;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final WindowsMediaControls? _systemControls =
      hasWindowsMediaIntegration ? WindowsMediaControls() : null;
  Timer? _systemTimelineTimer;

  @override
  late final EqualizerController equalizer = MpvEqualizerController(_player);
  late final _crossfade = CrossfadeCoordinator(_DesktopPlayerAdapter(this));

  /// Cola en el orden en que media_kit la va a reproducir. Con el shuffle
  /// activo media_kit rearma su playlist en otro orden y los índices que
  /// reporta pasan a ser de ESE orden — por eso esta lista se reconstruye
  /// a partir de su playlist en vez de quedar fija en el orden original,
  /// si no la pantalla mostraría una canción y sonaría otra.
  List<MediaItem> _items = [];
  final Map<String, MediaItem> _byId = {};

  AudioServiceShuffleMode _shuffleMode = AudioServiceShuffleMode.none;
  AudioServiceRepeatMode _repeatMode = AudioServiceRepeatMode.none;
  bool _currentLiked = false;

  Timer? _sleepTimer;
  @override
  final ValueNotifier<DateTime?> sleepTimerEndsAt = ValueNotifier(null);

  // Mezclador automático: mientras suena con sus propios reproductores,
  // los controles del sistema se redirigen a él (igual que MyAudioHandler
  // con la notificación de Android).
  bool _externalControlActive = false;
  Future<void> Function()? _externalPlay;
  Future<void> Function()? _externalPause;
  Future<void> Function()? _externalStop;
  Future<void> Function()? _externalSkipNext;

  DesktopAudioHandler() {
    _subscriptions.add(_player.stream.playing.listen((_) => _emit()));
    _subscriptions.add(_player.stream.position.listen((_) => _emit()));
    _subscriptions.add(_player.stream.buffering.listen((_) => _emit()));
    _subscriptions.add(_player.stream.playlist.listen(_onPlaylistChanged));
    _subscriptions.add(_player.stream.duration.listen(_onDurationKnown));
    _subscriptions.add(mediaItem.listen((item) {
      final songId = item?.extras?['songId'] as int?;
      if (songId != null) unawaited(_refreshLikedState(songId));
    }));
    unawaited((equalizer as MpvEqualizerController).restore());
    _crossfade.attach();
    _attachSystemControls();
  }

  // ---- Controles del sistema (Windows) ----

  void _attachSystemControls() {
    final controls = _systemControls;
    if (controls == null) return;
    controls.listen((button) {
      switch (button) {
        case 'play':
          unawaited(play());
        case 'pause':
          unawaited(pause());
        case 'next':
          unawaited(skipToNext());
        case 'previous':
          if (!_externalControlActive) unawaited(skipToPrevious());
        case 'stop':
          unawaited(_externalControlActive ? _externalStop!() : pause());
      }
    });
    // Cambios reales (canción, play/pausa) se reflejan al toque; la barra de
    // tiempo del panel se refresca cada tanto mientras suena.
    _subscriptions.add(mediaItem.listen((_) => _syncSystemControls()));
    _subscriptions
        .add(_player.stream.playing.listen((_) => _syncSystemControls()));
    _systemTimelineTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (playbackState.value.playing) _syncSystemControls();
    });
  }

  void _syncSystemControls() {
    final controls = _systemControls;
    if (controls == null) return;
    final item = mediaItem.value;
    if (item == null) {
      unawaited(controls.clear());
      return;
    }
    final state = playbackState.value;
    final index = _player.state.playlist.index;
    unawaited(controls.update(
      title: item.title,
      artist: item.artist,
      album: item.album,
      playing: state.playing,
      position: state.position,
      duration: item.duration,
      canNext: _externalControlActive
          ? _externalSkipNext != null
          : index < _items.length - 1 ||
              _repeatMode == AudioServiceRepeatMode.all,
      canPrevious: !_externalControlActive,
    ));
  }

  // ---- Estado ----

  /// En desktop no hay MediaStore que diga cuánto dura cada canción si el
  /// archivo no trae el dato: se sabe recién cuando media_kit lo carga. Sin
  /// esto el MediaItem quedaba sin duración y la barra de progreso de
  /// "Reproduciendo" no dejaba adelantar ni atrasar.
  void _onDurationKnown(Duration duration) {
    if (duration <= Duration.zero) return;
    final index = _player.state.playlist.index;
    if (index < 0 || index >= _items.length) return;
    final current = _items[index];
    if (current.duration == duration) return;
    final updated = current.copyWith(duration: duration);
    _byId[updated.id] = updated;
    _items = [
      for (final item in _items) item.id == updated.id ? updated : item
    ];
    queue.add(_items);
    if (mediaItem.value?.id == updated.id) mediaItem.add(updated);
  }

  bool get _shuffleEnabled =>
      _shuffleMode == AudioServiceShuffleMode.all ||
      _shuffleMode == AudioServiceShuffleMode.group;

  void _onPlaylistChanged(Playlist playlist) {
    final ordered = <MediaItem>[];
    for (final media in playlist.medias) {
      final item = _byId[media.extras?['id']];
      if (item != null) ordered.add(item);
    }
    if (ordered.length == playlist.medias.length &&
        !_sameOrder(ordered, _items)) {
      _items = ordered;
      queue.add(_items);
    }

    if (_externalControlActive) return;
    final index = playlist.index;
    if (index < 0 || index >= _items.length) return;
    final current = _items[index];
    if (mediaItem.value?.id == current.id) return;
    mediaItem.add(current);
    unawaited(_crossfade.onTrackChanged(index));
    final songId = current.extras?['songId'] as int?;
    if (songId != null) unawaited(_recentSongs.recordPlayed(songId));
  }

  bool _sameOrder(List<MediaItem> a, List<MediaItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  Future<void> _refreshLikedState(int songId) async {
    _currentLiked = await _favorites.isLiked(songId);
    _emit();
  }

  void _emit() {
    // Con el Automix sonando, el estado lo reporta él (reportExternalState).
    if (_externalControlActive) return;
    final state = _player.state;
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (state.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.custom(
          androidIcon: _currentLiked
              ? 'drawable/ic_thumb_up_filled'
              : 'drawable/ic_thumb_up_outline',
          label: _currentLiked ? 'Quitar me gusta' : 'Me gusta',
          name: 'like',
        ),
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      playing: state.playing,
      processingState: state.buffering
          ? AudioProcessingState.buffering
          : AudioProcessingState.ready,
      updatePosition: state.position,
      bufferedPosition: state.buffer,
      speed: state.rate,
      queueIndex: state.playlist.index,
      shuffleMode: _shuffleMode,
      repeatMode: _repeatMode,
    ));
  }

  // ---- Controles ----

  @override
  Future<void> play() async {
    if (_externalControlActive) return _externalPlay!();
    await _player.play();
  }

  @override
  Future<void> pause() async {
    if (_externalControlActive) return _externalPause!();
    await _player.pause();
    await _savePosition();
  }

  @override
  Future<void> stop() async {
    if (_externalControlActive) return _externalStop!();
    await _savePosition();
    await _player.stop();
    mediaItem.add(null);
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
    if (_externalControlActive) {
      await _externalSkipNext?.call();
      return;
    }
    await _player.next();
  }

  @override
  Future<void> skipToPrevious() => _player.previous();

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _items.length) return;
    await _player.jump(index);
  }

  /// Reordena la cola actual (pantalla "A continuación"), igual que en
  /// Android.
  @override
  Future<void> moveQueueItem(int oldIndex, int newIndex) async {
    final items = List<MediaItem>.from(_items);
    if (oldIndex < 0 ||
        oldIndex >= items.length ||
        newIndex < 0 ||
        newIndex >= items.length) {
      return;
    }
    final item = items.removeAt(oldIndex);
    items.insert(newIndex, item);
    _items = items;
    queue.add(items);
    await _player.move(oldIndex, newIndex);
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    final items = List<MediaItem>.from(_items);
    if (index < 0 || index >= items.length) return;
    final removed = items.removeAt(index);
    _byId.remove(removed.id);
    _items = items;
    queue.add(items);
    await _player.remove(index);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    _shuffleMode = shuffleMode;
    await _player.setShuffle(_shuffleEnabled);
    _emit();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await _player.setPlaylistMode(switch (repeatMode) {
      AudioServiceRepeatMode.one => PlaylistMode.single,
      AudioServiceRepeatMode.all => PlaylistMode.loop,
      _ => PlaylistMode.none,
    });
    _repeatMode = repeatMode;
    _emit();
  }

  /// Mismas acciones propias que MyAudioHandler (botón de "me gusta" y
  /// shuffle de "Reproduciendo").
  @override
  Future<dynamic> customAction(String name,
      [Map<String, dynamic>? extras]) async {
    switch (name) {
      case 'like':
        final songId = mediaItem.value?.extras?['songId'] as int?;
        if (songId == null) return;
        _currentLiked = await _favorites.toggle(songId);
        _emit();
      case 'shuffle':
        await setShuffleMode(_shuffleEnabled
            ? AudioServiceShuffleMode.none
            : AudioServiceShuffleMode.all);
    }
  }

  /// Arma la cola con [items] y salta a [startIndex] — misma firma que
  /// `MyAudioHandler.setQueue` para que las pantallas no tengan que saber
  /// con cuál de los dos están hablando.
  @override
  Future<void> setQueue(
    List<MediaItem> items, {
    int startIndex = 0,
    bool resumeLastPosition = false,
  }) async {
    _byId
      ..clear()
      ..addEntries(items.map((item) => MapEntry(item.id, item)));
    _items = List<MediaItem>.from(items);
    if (items.isEmpty) {
      queue.add(_items);
      mediaItem.add(null);
      return;
    }

    var initialIndex = startIndex.clamp(0, items.length - 1);
    int? resumePositionMs;

    if (resumeLastPosition) {
      final prefs = await SharedPreferences.getInstance();
      final savedPath = prefs.getString(_lastSongPathKey);
      final savedPosition = prefs.getInt(_lastSongPositionKey);
      final savedIndex = savedPath == null
          ? -1
          : items.indexWhere((item) => item.id == savedPath);
      if (savedIndex >= 0) {
        initialIndex = savedIndex;
        resumePositionMs = savedPosition;
      }
    }

    queue.add(_items);
    await _player.open(
      Playlist(
        // El id viaja en extras para poder reconocer cada canción cuando
        // media_kit rearma la playlist (shuffle): ahí no se puede confiar en
        // el índice.
        items.map((item) => Media(item.id, extras: {'id': item.id})).toList(),
        index: initialIndex,
      ),
      play: false,
    );
    mediaItem.add(items[initialIndex]);
    if (resumePositionMs != null) {
      await _player.seek(Duration(milliseconds: resumePositionMs));
    }
    // open() apaga el shuffle de media_kit; si el usuario lo tenía prendido
    // se vuelve a aplicar sobre la cola nueva.
    if (_shuffleEnabled) await _player.setShuffle(true);
  }

  String get _lastSongPathKey => '${ActiveProfile.instance.key}.lastSongPath';
  String get _lastSongPositionKey =>
      '${ActiveProfile.instance.key}.lastSongPosition';

  Future<void> _savePosition() async {
    final item = mediaItem.value;
    if (item == null || _externalControlActive) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSongPathKey, item.id);
    await prefs.setInt(
        _lastSongPositionKey, _player.state.position.inMilliseconds);
  }

  // ---- Temporizador de apagado ----

  @override
  void setSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    sleepTimerEndsAt.value = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, () {
      unawaited(pause());
      sleepTimerEndsAt.value = null;
    });
  }

  @override
  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepTimerEndsAt.value = null;
  }

  // ---- Mezclador automático ----

  @override
  void refreshMediaItem(MediaItem item) {
    final old = _byId[item.id];
    if (old == null) return;
    final updated = item.copyWith(duration: item.duration ?? old.duration);
    _byId[item.id] = updated;
    _items = [for (final i in _items) i.id == item.id ? updated : i];
    queue.add(_items);
    if (mediaItem.value?.id == item.id) mediaItem.add(updated);
  }

  @override
  void takeExternalControl({
    required Future<void> Function() onPlay,
    required Future<void> Function() onPause,
    required Future<void> Function() onStop,
    Future<void> Function()? onSkipNext,
  }) {
    unawaited(_player.pause());
    _externalControlActive = true;
    _externalPlay = onPlay;
    _externalPause = onPause;
    _externalStop = onStop;
    _externalSkipNext = onSkipNext;
  }

  @override
  void releaseExternalControl() {
    if (!_externalControlActive) return;
    _externalControlActive = false;
    _externalPlay = null;
    _externalPause = null;
    _externalStop = null;
    _externalSkipNext = null;
    final index = _player.state.playlist.index;
    mediaItem.add(index >= 0 && index < _items.length ? _items[index] : null);
    _emit();
  }

  @override
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
    mediaItem.add(MediaItem(
      id: filePath,
      title: title,
      artist: artist,
      duration: duration,
      extras: mediaStoreId != null ? {'songId': mediaStoreId} : null,
    ));
    playbackState.add(PlaybackState(
      controls: [
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {MediaAction.seek},
      playing: playing,
      processingState: AudioProcessingState.ready,
      updatePosition: position,
      speed: 1.0,
    ));
    _syncSystemControls();
  }

  /// Libera el reproductor. Sólo debe llamarse al terminar el servicio.
  Future<void> dispose() async {
    _sleepTimer?.cancel();
    _systemTimelineTimer?.cancel();
    sleepTimerEndsAt.dispose();
    await _systemControls?.dispose();
    await _crossfade.dispose();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    await _player.dispose();
  }
}

/// Puente entre el reproductor de desktop (media_kit) y
/// [CrossfadeCoordinator].
class _DesktopPlayerAdapter implements MainPlayerAdapter {
  _DesktopPlayerAdapter(this._handler);

  final DesktopAudioHandler _handler;
  Player get _player => _handler._player;

  @override
  Duration get position => _player.state.position;
  @override
  Duration? get duration {
    final duration = _player.state.duration;
    return duration == Duration.zero ? null : duration;
  }

  @override
  bool get playing => _player.state.playing;
  @override
  Stream<Duration> get positionStream => _player.stream.position;
  @override
  int? get currentIndex {
    final index = _player.state.playlist.index;
    return index >= 0 && index < _handler._items.length ? index : null;
  }

  @override
  int? get nextIndex {
    final index = currentIndex;
    if (index == null) return null;
    if (index + 1 < _handler._items.length) return index + 1;
    return _player.state.playlistMode == PlaylistMode.loop ? 0 : null;
  }

  @override
  bool get repeatOne => _player.state.playlistMode == PlaylistMode.single;
  @override
  bool get externallyControlled => _handler._externalControlActive;

  @override
  String? idAt(int index) => index >= 0 && index < _handler._items.length
      ? _handler._items[index].id
      : null;

  @override
  int? songIdAt(int index) => index >= 0 && index < _handler._items.length
      ? (_handler._items[index].extras?['songId'] as int?)
      : null;

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume((volume * 100).clamp(0, 130).toDouble());

  @override
  Future<void> seekTo(int index, Duration position) async {
    if (currentIndex != index) await _player.jump(index);
    await _player.seek(position);
  }

  @override
  Future<void> play() => _player.play();
}
