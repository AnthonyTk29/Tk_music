import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'artwork_cache.dart';

class MyAudioHandler extends BaseAudioHandler with SeekHandler {
  final _player = AudioPlayer();
  final _artwork = ArtworkCache();
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  MyAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    _subscriptions.add(
      session.interruptionEventStream.listen((event) {
        if (event.begin) pause();
      }),
    );
    _subscriptions.add(
      session.becomingNoisyEventStream.listen((_) => pause()),
    );
    _subscriptions.add(
      _player.playbackEventStream.listen((event) {
        playbackState.add(_transformEvent(event));
      }),
    );
    _subscriptions.add(
      _player.currentIndexStream.listen(_onIndexChanged),
    );
  }

  void _onIndexChanged(int? index) {
    final items = queue.value;
    if (index == null || index >= items.length) return;
    mediaItem.add(items[index]);
    _attachArtwork(index);
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
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
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
    );
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() async {
    await _player.pause();
    await _savePosition();
  }

  @override
  Future<void> stop() async {
    await _savePosition();
    await _player.stop();
    mediaItem.add(null);
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() => _player.seekToNext();

  @override
  Future<void> skipToPrevious() => _player.seekToPrevious();

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= queue.value.length) return;
    await _player.seek(Duration.zero, index: index);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    await _player.setShuffleModeEnabled(
        shuffleMode == AudioServiceShuffleMode.all ||
            shuffleMode == AudioServiceShuffleMode.group);
    playbackState.add(playbackState.value.copyWith(shuffleMode: shuffleMode));
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await _player.setLoopMode(switch (repeatMode) {
      AudioServiceRepeatMode.one => LoopMode.one,
      AudioServiceRepeatMode.all => LoopMode.all,
      _ => LoopMode.off,
    });
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
  }

  Future<void> setQueue(List<MediaItem> items, {int startIndex = 0}) async {
    final prefs = await SharedPreferences.getInstance();
    final savedPath = prefs.getString('lastSongPath');
    final savedPosition = prefs.getInt('lastSongPosition');
    final savedIndex = savedPath == null
        ? -1
        : items.indexWhere((item) => item.id == savedPath);
    final initialIndex = savedIndex >= 0 ? savedIndex : startIndex;

    queue.add(items);
    await _player.setAudioSources(
      items.map((item) => AudioSource.uri(Uri.file(item.id))).toList(),
      initialIndex: initialIndex,
    );
    mediaItem.add(items[initialIndex]);
    _attachArtwork(initialIndex);
    if (savedIndex >= 0 && savedPosition != null) {
      await _player.seek(Duration(milliseconds: savedPosition));
    }
  }

  Future<void> _savePosition() async {
    final item = mediaItem.value;
    if (item == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lastSongPath', item.id);
    await prefs.setInt('lastSongPosition', _player.position.inMilliseconds);
  }

  /// Libera el reproductor. Sólo debe llamarse al terminar el servicio.
  Future<void> dispose() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    await _player.dispose();
  }
}
